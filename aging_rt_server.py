#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""aging_rt_server.py — 실제 토폴로지 10세션 아징: 서버+sink 측 (s.xdn에서 실행)

테스트 multi-fec 서버를 :PORT 로 띄우고, --wg 가 가리키는 sink 소켓에서
복호된 태그 패킷(S%02d#seq)을 세션별로 카운트한다. 서버 프로세스 RSS/CPU를
주기 샘플링하여 누수/크래시/cross-talk를 시간축으로 관찰한다.
DURATION 후 자동 종료하고 요약+per-session 카운트를 파일로 남긴다.
"""
import argparse, os, socket, subprocess, sys, threading, time

BIN = "/usr/sbin/multi-fec-dist"
CLK = os.sysconf("SC_CLK_TCK")


def rss_kb(pid):
    rss = hwm = 0
    try:
        with open("/proc/%d/status" % pid) as f:
            for ln in f:
                if ln.startswith("VmRSS:"):
                    rss = int(ln.split()[1])
                elif ln.startswith("VmHWM:"):
                    hwm = int(ln.split()[1])
    except OSError:
        pass
    return rss, hwm


def cpu_ticks(pid):
    try:
        with open("/proc/%d/stat" % pid) as f:
            d = f.read()
        r = d[d.rfind(")") + 2:].split()
        return int(r[11]) + int(r[12])
    except (OSError, ValueError, IndexError):
        return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", required=True)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--sessions", type=int, default=10)
    ap.add_argument("--listen", required=True, help="공개IP:PORT (예 218.154.1.134:4443)")
    ap.add_argument("--sink-port", type=int, required=True)
    ap.add_argument("--key", required=True)
    ap.add_argument("--fec", default="20:5")
    ap.add_argument("--mtu", default="1350")
    ap.add_argument("--sample", type=float, default=60.0)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    n = a.sessions

    sink = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sink.bind(("127.0.0.1", a.sink_port))
    sink.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 * 1024 * 1024)
    sink.setblocking(False)

    cmd = [BIN, "-s", "-l", a.listen, "--wg", "127.0.0.1:%d" % a.sink_port,
           "-k", a.key, "--obfs-mode", "quic", "--auth-interval", "60",
           "-f", a.fec, "--fec-timeout", "5", "--mode", a.mode, "--mtu", a.mtu,
           "--decode-buf", "8000", "--queue-len", "500", "--sock-buf", "4096",
           "--log-level", "2"]
    srv = subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.0)
    if srv.poll() is not None:
        print("server launch failed", file=sys.stderr); sys.exit(1)

    recv = [0] * n
    corrupt = [0]
    badsess = [0]
    stop = threading.Event()

    def collector():
        while not stop.is_set():
            try:
                data, _ = sink.recvfrom(65535)
            except (BlockingIOError, OSError):
                time.sleep(0.001); continue
            if len(data) >= 4 and data[:1] == b"S" and data[3:4] == b"#":
                try:
                    si = int(data[1:3])
                except ValueError:
                    corrupt[0] += 1; continue
                if 0 <= si < n:
                    recv[si] += 1
                else:
                    badsess[0] += 1   # 존재하지 않는 세션 번호 = cross-talk
            else:
                corrupt[0] += 1       # 헤더 깨짐 = 내용 오염
    col = threading.Thread(target=collector); col.start()

    out = open(a.out, "w", buffering=1)
    def log(s):
        print(s); out.write(s + "\n")

    log("### RT-AGING server mode=%s sessions=%d dur=%.0fs(%.1fh) listen=%s ###"
        % (a.mode, n, a.duration, a.duration / 3600.0, a.listen))
    log("%-8s %-10s %-8s %-9s %-9s %-8s %-9s" %
        ("t(s)", "pkt/s", "CPU%", "RSS_MB", "peak_MB", "corrupt", "crosstalk"))

    start = time.monotonic(); end = start + a.duration
    prev_recv = 0; prev_cpu = cpu_ticks(srv.pid); prev_t = start
    crashed = False; samples = []
    try:
        while time.monotonic() < end:
            tgt = min(time.monotonic() + a.sample, end)
            while time.monotonic() < tgt:
                time.sleep(min(2.0, max(0.0, tgt - time.monotonic())))
                if srv.poll() is not None:
                    crashed = True; break
            if crashed:
                break
            now = time.monotonic()
            cur = sum(recv); cc = cpu_ticks(srv.pid); dt = now - prev_t
            pps = (cur - prev_recv) / dt if dt else 0
            cpu = (cc - prev_cpu) / CLK / dt * 100 if dt else 0
            r, h = rss_kb(srv.pid)
            log("%-8.0f %-10.0f %-8.0f %-9.1f %-9.1f %-8d %-9d" %
                (now - start, pps, cpu, r / 1024., h / 1024., corrupt[0], badsess[0]))
            samples.append({"rss": r / 1024., "hwm": h / 1024.})
            prev_recv, prev_cpu, prev_t = cur, cc, now
    finally:
        stop.set(); col.join()
        srv_alive = srv.poll() is None
        srv.terminate()
        try: srv.wait(timeout=3)
        except subprocess.TimeoutExpired: srv.kill()
        sink.close()

    total_recv = sum(recv)
    log("### RESULT mode=%s ###" % a.mode)
    log("recv_total=%d corrupt=%d crosstalk=%d srv_alive=%s crashed=%s"
        % (total_recv, corrupt[0], badsess[0], srv_alive, crashed))
    log("per_session_recv=%s" % recv)
    if len(samples) >= 3:
        body = samples[1:]; half = len(body) // 2
        early = sum(s["rss"] for s in body[:half]) / max(1, half)
        late = sum(s["rss"] for s in body[half:]) / max(1, len(body) - half)
        peak = max(s["hwm"] for s in samples)
        log("rss_early=%.1f rss_late=%.1f growth=%.2f peak=%.1f"
            % (early, late, late - early, peak))
    out.close()


if __name__ == "__main__":
    main()
