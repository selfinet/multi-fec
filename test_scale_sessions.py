#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
test_scale_sessions.py — 다중 세션(session_id) 부하/스케일 테스트

서버 1대에 multi-fec 클라이언트 프로세스를 N개 동시에 띄워(= session_id N개)
세션 수를 1→10(설정 가능)으로 늘리며 서버 측 자원·처리량·세션 간 간섭을 측정한다.

토폴로지 (단일 호스트, 루프백):
    blaster_i ──UDP──▶ client_i(-l LP_i) ──FEC/mud──▶ server(-l SP, --wg W) ──▶ sink(W)
                          (프로세스마다 /dev/urandom session_id 1개)

  - 1 클라이언트 프로세스 = 1 세션 (g_session_id는 프로세스 시작 시 1회 생성).
  - 서버는 session_id별 독립 conn_info(독립 FEC 디코더)를 만든다 → 세션 간 FEC 그룹 무간섭.
  - 페이로드에 세션 번호 + 시퀀스를 박아넣어, 다른 세션 내용이 섞여 들어오면(cross-talk)
    corrupt로 잡힌다.

측정 항목 (세션 수별):
  - 서버 프로세스 RSS / 피크RSS(VmHWM), CPU% (Linux /proc 기반)
  - 집계 전달률, throughput (pkt/s, Mbps)
  - 세션 간 내용 오염(cross-talk) 0 여부
  - 모든 프로세스 생존 여부

주의: multi-fec 바이너리는 Linux용이다. 빌드 호스트나 c.xdn에서 실행할 것.
      /proc 미존재(mac 등)면 자원 지표는 건너뛰고 처리량/무결성만 측정한다.

사용:
  python3 test_scale_sessions.py
  python3 test_scale_sessions.py --mode 2 --fec 20:5 --sessions 1,2,4,8,10 \
          --duration 6 --rate 400 --mtu 1250
"""

import argparse
import os
import socket
import subprocess
import sys
import threading
import time

BIN = os.path.join(os.path.dirname(os.path.abspath(__file__)), "multi-fec")
KEY = "scale-test-key"
HAVE_PROC = os.path.isdir("/proc")
CLK_TCK = os.sysconf("SC_CLK_TCK") if hasattr(os, "sysconf") else 100

passed = 0
failed = 0


def check(name, cond, extra=""):
    global passed, failed
    if cond:
        passed += 1
        print("  ✓ %s %s" % (name, extra))
    else:
        failed += 1
        print("  ✗ %s %s" % (name, extra))


def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


def proc_rss_kb(pid):
    """현재 RSS, 피크 RSS(VmHWM) (kB). 실패 시 (0, 0)."""
    if not HAVE_PROC:
        return (0, 0)
    rss = hwm = 0
    try:
        with open("/proc/%d/status" % pid) as f:
            for line in f:
                if line.startswith("VmRSS:"):
                    rss = int(line.split()[1])
                elif line.startswith("VmHWM:"):
                    hwm = int(line.split()[1])
    except (OSError, ValueError):
        pass
    return (rss, hwm)


def proc_cpu_ticks(pid):
    """프로세스 전체 utime+stime (clock ticks). 실패 시 0."""
    if not HAVE_PROC:
        return 0
    try:
        with open("/proc/%d/stat" % pid) as f:
            data = f.read()
        # comm 필드에 공백/괄호가 있을 수 있으므로 마지막 ')' 이후를 파싱
        rest = data[data.rfind(")") + 2:].split()
        # rest[0]=state(field 3). utime=field14 -> rest[11], stime=field15 -> rest[12]
        return int(rest[11]) + int(rest[12])
    except (OSError, ValueError, IndexError):
        return 0


def start_server(sp, wg, mode, fec, mtu):
    cmd = [BIN, "-s", "-l", "127.0.0.1:%d" % sp,
           "--wg", "127.0.0.1:%d" % wg, "-k", KEY,
           "--mode", mode, "-f", fec, "--fec-timeout", "8",
           "--mtu", str(mtu), "--sock-buf", "4096", "--log-level", "2"]
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def start_client(lp, sp, mode, fec, mtu):
    cmd = [BIN, "-c", "-l", "127.0.0.1:%d" % lp,
           "--path", "0.0.0.0:127.0.0.1:%d" % sp, "-k", KEY,
           "--mode", mode, "-f", fec, "--fec-timeout", "8",
           "--mtu", str(mtu), "--sock-buf", "4096", "--log-level", "2"]
    return subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def run_round(n_sessions, args, srv, wg_sink):
    """세션 N개를 동시에 띄워 부하를 주고 측정 결과 dict 반환."""
    sp = args._sp
    payload_sz = max(64, args.mtu - 200)  # FEC/obfs 헤더 여유

    # 세션(클라이언트 프로세스) N개 기동
    clients = []
    lps = []
    for i in range(n_sessions):
        lp = free_port()
        lps.append(lp)
        clients.append(start_client(lp, sp, args.mode, args.fec, args.mtu))

    # mud 경로 RUNNING 대기 (세션 많을수록 약간 더)
    time.sleep(args.warmup)

    sent_per = [0] * n_sessions
    stop_flag = threading.Event()

    def blaster(sess_idx, lp):
        tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        interval = 1.0 / args.rate if args.rate > 0 else 0
        seq = 0
        body = bytes((i & 0xFF) for i in range(payload_sz - 12))
        while not stop_flag.is_set():
            hdr = ("S%02d#%08d|" % (sess_idx, seq)).encode()
            try:
                tx.sendto(hdr + body, ("127.0.0.1", lp))
            except OSError:
                pass
            seq += 1
            sent_per[sess_idx] = seq
            if interval:
                time.sleep(interval)
        tx.close()

    # CPU/시간 측정 시작점
    cpu0 = proc_cpu_ticks(srv.pid)
    t0 = time.monotonic()

    threads = [threading.Thread(target=blaster, args=(i, lps[i]))
               for i in range(n_sessions)]
    for t in threads:
        t.start()

    # 수집 (전송과 병행)
    recv_per = [0] * n_sessions
    corrupt = 0
    deadline = time.monotonic() + args.duration
    wg_sink.setblocking(False)
    while time.monotonic() < deadline:
        try:
            data, _ = wg_sink.recvfrom(65535)
        except BlockingIOError:
            time.sleep(0.001)
            continue
        except OSError:
            continue
        # 세션 번호 파싱: "S%02d#..."
        if len(data) >= 4 and data[:1] == b"S" and data[3:4] == b"#":
            try:
                si = int(data[1:3])
            except ValueError:
                corrupt += 1
                continue
            if 0 <= si < n_sessions:
                recv_per[si] += 1
            else:
                corrupt += 1  # 존재하지 않는 세션 번호 = cross-talk/오염
        else:
            corrupt += 1

    stop_flag.set()
    for t in threads:
        t.join()

    t1 = time.monotonic()
    cpu1 = proc_cpu_ticks(srv.pid)
    wall = t1 - t0
    rss, hwm = proc_rss_kb(srv.pid)
    cpu_pct = (cpu1 - cpu0) / CLK_TCK / wall * 100.0 if wall > 0 else 0.0

    # 잔여 수집(파이프라인에 남은 패킷) 짧게
    drain_end = time.monotonic() + 0.5
    while time.monotonic() < drain_end:
        try:
            data, _ = wg_sink.recvfrom(65535)
        except (BlockingIOError, OSError):
            time.sleep(0.005)
            continue
        if len(data) >= 4 and data[:1] == b"S" and data[3:4] == b"#":
            try:
                si = int(data[1:3])
                if 0 <= si < n_sessions:
                    recv_per[si] += 1
            except ValueError:
                pass

    total_sent = sum(sent_per)
    total_recv = sum(recv_per)
    clients_alive = all(c.poll() is None for c in clients)
    srv_alive = srv.poll() is None
    active_sessions = sum(1 for r in recv_per if r > 0)

    # 세션 종료
    for c in clients:
        c.terminate()
    for c in clients:
        try:
            c.wait(timeout=3)
        except subprocess.TimeoutExpired:
            c.kill()

    ratio = (total_recv / total_sent) if total_sent else 0.0
    pkt_s = total_recv / wall if wall else 0.0
    mbps = pkt_s * payload_sz * 8 / 1e6

    return {
        "n": n_sessions, "sent": total_sent, "recv": total_recv,
        "ratio": ratio, "pkt_s": pkt_s, "mbps": mbps,
        "rss_mb": rss / 1024.0, "hwm_mb": hwm / 1024.0, "cpu_pct": cpu_pct,
        "corrupt": corrupt, "active": active_sessions,
        "srv_alive": srv_alive, "cli_alive": clients_alive,
        "payload_sz": payload_sz,
    }


def run_aging(args):
    """단일 세션수를 args.aging초 동안 유지하며 주기적으로 자원/처리량을 샘플링한다.
    누수(RSS 우상향), 크래시, 처리량 붕괴, cross-talk 오염을 시간축으로 관찰."""
    n = int(args.sessions.split(",")[0])  # 아징은 첫 세션수 사용 (기본 10)
    payload_sz = max(64, args.mtu - 200)
    total = args.aging

    sp = free_port()
    wg = free_port()
    sink = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sink.bind(("127.0.0.1", wg))
    sink.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    sink.setblocking(False)

    print("=" * 72)
    print("multi-fec 다중 세션 아징 소크")
    print("sessions=%d mode=%s fec=%s mtu=%d rate=%d pkt/s/sess total=%.0fs(%.1fh) sample=%.0fs"
          % (n, args.mode, args.fec, args.mtu, args.rate, total, total / 3600.0, args.sample))
    print("자원 측정(/proc): %s" % ("ON" if HAVE_PROC else "OFF"))
    print("=" * 72)

    srv = start_server(sp, wg, args.mode, args.fec, args.mtu)
    time.sleep(1.0)
    if srv.poll() is not None:
        print("서버 기동 실패")
        sys.exit(1)

    clients, lps = [], []
    for i in range(n):
        lp = free_port()
        lps.append(lp)
        clients.append(start_client(lp, sp, args.mode, args.fec, args.mtu))
    time.sleep(args.warmup)

    stop_flag = threading.Event()
    sent_total = [0] * n
    recv_total = [0] * n
    corrupt_total = [0]

    def blaster(idx, lp):
        tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        interval = 1.0 / args.rate if args.rate > 0 else 0
        seq = 0
        body = bytes((i & 0xFF) for i in range(payload_sz - 12))
        while not stop_flag.is_set():
            hdr = ("S%02d#%08d|" % (idx, seq)).encode()
            try:
                tx.sendto(hdr + body, ("127.0.0.1", lp))
            except OSError:
                pass
            seq += 1
            sent_total[idx] = seq
            if interval:
                time.sleep(interval)
        tx.close()

    def collector():
        while not stop_flag.is_set():
            try:
                data, _ = sink.recvfrom(65535)
            except (BlockingIOError, OSError):
                time.sleep(0.001)
                continue
            if len(data) >= 4 and data[:1] == b"S" and data[3:4] == b"#":
                try:
                    si = int(data[1:3])
                except ValueError:
                    corrupt_total[0] += 1
                    continue
                if 0 <= si < n:
                    recv_total[si] += 1
                else:
                    corrupt_total[0] += 1
            else:
                corrupt_total[0] += 1

    threads = [threading.Thread(target=blaster, args=(i, lps[i])) for i in range(n)]
    col = threading.Thread(target=collector)
    for t in threads:
        t.start()
    col.start()

    start = time.monotonic()
    end = start + total
    samples = []
    prev_recv = 0
    prev_cpu = proc_cpu_ticks(srv.pid)
    prev_t = start
    crashed = False

    print("\n%-8s %-9s %-8s %-9s %-9s %-8s %-7s" %
          ("t(s)", "Mbps", "CPU%", "RSS_MB", "peak_MB", "alive", "corrupt"))
    try:
        while time.monotonic() < end:
            # 다음 샘플 시각까지 대기 (정밀 sleep 금지 회피: 짧게 쪼개 생존 체크)
            target = min(time.monotonic() + args.sample, end)
            while time.monotonic() < target:
                time.sleep(min(2.0, max(0.0, target - time.monotonic())))
                if srv.poll() is not None:
                    crashed = True
                    break
            if crashed:
                break

            now = time.monotonic()
            cur_recv = sum(recv_total)
            cur_cpu = proc_cpu_ticks(srv.pid)
            dt = now - prev_t
            d_recv = cur_recv - prev_recv
            pkt_s = d_recv / dt if dt else 0
            mbps = pkt_s * payload_sz * 8 / 1e6
            cpu_pct = (cur_cpu - prev_cpu) / CLK_TCK / dt * 100.0 if dt else 0
            rss, hwm = proc_rss_kb(srv.pid)
            cli_alive = sum(1 for c in clients if c.poll() is None)
            elapsed = now - start
            print("%-8.0f %-9.2f %-8.0f %-9.1f %-9.1f %-8s %-7d" %
                  (elapsed, mbps, cpu_pct, rss / 1024.0, hwm / 1024.0,
                   "%d/%d" % (cli_alive, n), corrupt_total[0]))
            sys.stdout.flush()
            samples.append({"t": elapsed, "mbps": mbps, "cpu": cpu_pct,
                            "rss": rss / 1024.0, "hwm": hwm / 1024.0,
                            "cli_alive": cli_alive, "corrupt": corrupt_total[0]})
            prev_recv, prev_cpu, prev_t = cur_recv, cur_cpu, now
    finally:
        stop_flag.set()
        for t in threads:
            t.join()
        col.join()
        for c in clients:
            c.terminate()
        for c in clients:
            try:
                c.wait(timeout=3)
            except subprocess.TimeoutExpired:
                c.kill()
        srv_alive_end = srv.poll() is None
        srv.terminate()
        try:
            srv.wait(timeout=3)
        except subprocess.TimeoutExpired:
            srv.kill()
        sink.close()

    # 판정
    print("\n" + "=" * 72)
    print("아징 결과 (sessions=%d, %.1fh)" % (n, total / 3600.0))
    print("=" * 72)
    total_sent = sum(sent_total)
    total_recv = sum(recv_total)
    ratio = total_recv / total_sent if total_sent else 0
    print("총 송신=%d 수신=%d 전달률=%.1f%%  누적 corrupt=%d"
          % (total_sent, total_recv, ratio * 100, corrupt_total[0]))

    check("아징: 서버 끝까지 생존(크래시 없음)", srv_alive_end and not crashed)
    check("아징: cross-talk/오염 0", corrupt_total[0] == 0,
          "[corrupt=%d]" % corrupt_total[0])

    if HAVE_PROC and len(samples) >= 3:
        # 누수 판정: 후반 절반 평균 RSS vs 전반 절반 평균. 워밍업 첫 샘플 제외.
        body = samples[1:]
        half = len(body) // 2
        early = sum(s["rss"] for s in body[:half]) / max(1, half)
        late = sum(s["rss"] for s in body[half:]) / max(1, len(body) - half)
        growth = late - early
        peak = max(s["hwm"] for s in samples)
        print("RSS 전반평균=%.1fMB 후반평균=%.1fMB 증가=%.2fMB 피크=%.1fMB"
              % (early, late, growth, peak))
        # 3시간 동안 후반 RSS 증가가 2MB 미만이면 누수 없음으로 본다
        check("아징: 메모리 누수 없음(후반 RSS 증가 < 2MB)", growth < 2.0,
              "[+%.2fMB]" % growth)

    print("\n결과: %d 통과 / %d 실패" % (passed, failed))
    sys.exit(1 if failed else 0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", default="1", help="FEC 모드 0/1/2 (기본 1)")
    ap.add_argument("--fec", default="20:5", help="FEC 비율 x:y (기본 20:5)")
    ap.add_argument("--mtu", type=int, default=1250)
    ap.add_argument("--sessions", default="1,2,4,8,10",
                    help="측정할 세션 수 목록 (콤마 구분)")
    ap.add_argument("--duration", type=float, default=6.0, help="라운드당 측정 시간(초)")
    ap.add_argument("--rate", type=int, default=400,
                    help="세션당 송신 속도 pkt/s (0=무제한)")
    ap.add_argument("--warmup", type=float, default=3.0, help="mud RUNNING 대기(초)")
    ap.add_argument("--aging", type=float, default=0.0,
                    help="아징 소크 총 시간(초). >0이면 단일 세션수를 이 시간만큼 유지하며 주기 샘플링")
    ap.add_argument("--sample", type=float, default=60.0,
                    help="아징 모드 샘플링 간격(초)")
    args = ap.parse_args()

    if args.aging > 0:
        return run_aging(args)

    if not os.path.exists(BIN):
        print("multi-fec 바이너리 없음: %s (Linux 호스트에서 make 후 실행)" % BIN)
        sys.exit(1)

    counts = [int(x) for x in args.sessions.split(",") if x.strip()]
    if any(c > 200 for c in counts):
        print("⚠ max_conn_num=200 초과 세션은 서버가 거부한다 (common.h:112)")

    print("=" * 72)
    print("multi-fec 다중 세션 부하/스케일 테스트")
    print("mode=%s fec=%s mtu=%d  rate=%d pkt/s/sess  duration=%ds  sessions=%s"
          % (args.mode, args.fec, args.mtu, args.rate, args.duration, counts))
    print("자원 측정(/proc): %s" % ("ON" if HAVE_PROC else "OFF (mac 등 — throughput/무결성만)"))
    print("=" * 72)

    # 서버 1대 + sink 1개를 전체 라운드 공유 (세션 누적 메모리 추세 관찰)
    sp = free_port()
    wg = free_port()
    sink = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sink.bind(("127.0.0.1", wg))
    sink.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 * 1024 * 1024)
    args._sp = sp

    srv = start_server(sp, wg, args.mode, args.fec, args.mtu)
    time.sleep(1.0)
    if srv.poll() is not None:
        print("서버 기동 실패")
        sys.exit(1)

    rows = []
    try:
        for n in counts:
            print("\n[세션 %d개]" % n)
            r = run_round(n, args, srv, sink)
            rows.append(r)
            print("    sent=%d recv=%d ratio=%.1f%%  %.0f pkt/s  %.2f Mbps"
                  % (r["sent"], r["recv"], r["ratio"] * 100, r["pkt_s"], r["mbps"]))
            print("    RSS=%.1fMB peak=%.1fMB  CPU=%.0f%%  active_sess=%d/%d"
                  % (r["rss_mb"], r["hwm_mb"], r["cpu_pct"], r["active"], n))
            check("세션 %d: 서버/클라이언트 생존" % n, r["srv_alive"] and r["cli_alive"])
            check("세션 %d: cross-talk/오염 0" % n, r["corrupt"] == 0,
                  "[corrupt=%d]" % r["corrupt"])
            check("세션 %d: 모든 세션 활성(최소1패킷 수신)" % n,
                  r["active"] == n, "[%d/%d]" % (r["active"], n))
    finally:
        srv.terminate()
        try:
            srv.wait(timeout=3)
        except subprocess.TimeoutExpired:
            srv.kill()
        sink.close()

    # 스케일 요약 테이블
    print("\n" + "=" * 72)
    print("스케일 요약")
    print("=" * 72)
    print("%-6s %-9s %-9s %-8s %-9s %-9s %-7s" %
          ("sess", "ratio%", "Mbps", "CPU%", "RSS_MB", "peak_MB", "corrupt"))
    for r in rows:
        print("%-6d %-9.1f %-9.2f %-8.0f %-9.1f %-9.1f %-7d" %
              (r["n"], r["ratio"] * 100, r["mbps"], r["cpu_pct"],
               r["rss_mb"], r["hwm_mb"], r["corrupt"]))

    if HAVE_PROC and len(rows) >= 2:
        base, last = rows[0], rows[-1]
        dr = last["rss_mb"] - base["rss_mb"]
        per = dr / (last["n"] - base["n"]) if last["n"] != base["n"] else 0
        print("\nRSS 증가: %.1fMB (%d→%d세션), 세션당 ≈%.2fMB"
              % (dr, base["n"], last["n"], per))

    print("\n" + "=" * 72)
    print("결과: %d 통과 / %d 실패" % (passed, failed))
    print("=" * 72)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
