#!/usr/bin/env python3
"""다중 클라이언트 다운스트림(서버→클라이언트) 전달 검증.

기존 스위트가 비어 있던 자리를 메운다. test_scale_sessions.py 의 cross-talk 검사는
wg sink 도착분, 즉 업스트림(클라이언트→서버)만 본다. 서버가 다운스트림을 어느
클라이언트 경로로 내보내는지는 아무 테스트도 확인하지 않았고, 그 결과 클라이언트가
2개 이상일 때 서버가 A의 패킷을 B의 경로로 보내는 결함이 v1.0.2까지 남아 있었다.
(B는 conv 불일치로 조용히 버리므로 내용 오염이 아니라 A의 다운스트림 소실로 나타난다)

  blaster_i ──▶ client_i ──mud──▶ server ──▶ wg_echo ──echo──▶ server ──▶ client_? ──▶ blaster_?

각 blaster 가 자기 태그를 되받은 비율 = 그 클라이언트의 다운스트림 전달률.
남의 태그를 받으면 오배송(내용 오염).

usage:
  python3 test_downstream_multi.py                 # 전체 모드 × 세션수 매트릭스
  MP=failover N=2 python3 test_downstream_multi.py --single
"""
import os, socket, subprocess, sys, time, signal, threading, collections, tempfile

BIN  = os.environ.get("BIN", "./multi-fec")
KEY  = "dsmc-test-key"
# 문턱은 여유 있게: 한 호스트에서 서버1+클라N+파이썬 중계가 같이 돌아 루프백
# tail 손실이 세션당 몇 %씩 튄다(반복 측정 92~100%). 이 테스트가 잡아야 하는
# 결함은 특정 세션이 0~33%로 눌리는 형태이므로 80%로도 충분히 구분된다.
PASS_PCT = 80.0

def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close(); return p

def run_case(mp, n, pkts=50, rate=20, fec=False, logdir=None):
    """한 조합 실행 → (최저 전달률%, 오배송 건수, 세션별 전달률 목록)"""
    SP, WG = free_port(), free_port()
    LP = [free_port() for _ in range(n)]

    wg = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    wg.bind(("127.0.0.1", WG))
    stop = threading.Event()

    def echo_loop():
        wg.settimeout(0.2)
        while not stop.is_set():
            try:
                d, a = wg.recvfrom(65535)
            except socket.timeout:
                continue
            except OSError:
                break
            wg.sendto(d, a)
    th = threading.Thread(target=echo_loop, daemon=True); th.start()

    procs, logs = [], []
    def spawn(args, tag):
        f = open(os.path.join(logdir, tag + ".log"), "w") if logdir \
            else tempfile.TemporaryFile()
        logs.append(f)
        procs.append(subprocess.Popen(args, stdout=f, stderr=subprocess.STDOUT))

    fecarg = [] if fec else ["--disable-fec"]
    common = ["-k", KEY, "--multipath-mode", mp, "--log-level", "4"] + fecarg
    spawn([BIN, "-s", "-l", "127.0.0.1:%d" % SP,
           "--wg", "127.0.0.1:%d" % WG] + common, "srv")
    time.sleep(0.6)
    for i in range(n):
        spawn([BIN, "-c", "-l", "127.0.0.1:%d" % LP[i],
               "--path", "0.0.0.0:127.0.0.1:%d" % SP] + common, "cli%d" % (i + 1))
    time.sleep(2.5)   # 경로 PROBING → RUNNING

    socks = []
    for _ in range(n):
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.bind(("127.0.0.1", 0)); s.setblocking(False); socks.append(s)

    recv = collections.Counter()
    def drain():
        for i, s in enumerate(socks):
            while True:
                try:
                    d, _ = s.recvfrom(65535)
                except BlockingIOError:
                    break
                recv[(i + 1, int(d[1:2]) if d[:1] == b"S" else 0)] += 1

    interval = 1.0 / rate
    for seq in range(1, pkts + 1):
        for i, s in enumerate(socks):
            s.sendto(b"S%d#%06d" % (i + 1, seq) + b"x" * 200, ("127.0.0.1", LP[i]))
        t = time.time() + interval
        while time.time() < t:
            drain(); time.sleep(0.002)

    t = time.time() + 3.0
    while time.time() < t:
        drain(); time.sleep(0.005)

    stop.set(); th.join(timeout=1); wg.close()
    for p in procs: p.send_signal(signal.SIGTERM)
    time.sleep(0.4)
    for p in procs:
        if p.poll() is None: p.kill()
    for f in logs:
        try: f.close()
        except Exception: pass
    for s in socks: s.close()

    pcts = [100.0 * recv[(i, i)] / pkts for i in range(1, n + 1)]
    mis  = sum(v for (r, t), v in recv.items() if t != r)
    return min(pcts), mis, pcts

def main():
    if not os.path.exists(BIN):
        print("바이너리 없음: %s (make 먼저)" % BIN); return 1

    if "--single" in sys.argv:
        mp = os.environ.get("MP", "failover")
        n  = int(os.environ.get("N", "2"))
        worst, mis, pcts = run_case(mp, n)
        print("%s N=%d → %s  최저 %.1f%%  오배송 %d"
              % (mp, n, ["%.0f%%" % p for p in pcts], worst, mis))
        return 0 if (worst >= PASS_PCT and mis == 0) else 1

    cases = [(mp, n, fec)
             for fec in (False, True)
             for mp in ("failover", "duplicate", "aggregate", "aggregate-duplicate")
             for n in (1, 2, 4)]
    npass = nfail = 0
    print("=" * 72)
    print("다중 클라이언트 다운스트림 전달 (기준: 모든 세션 ≥%.0f%%, 오배송 0)" % PASS_PCT)
    print("=" * 72)
    for mp, n, fec in cases:
        worst, mis, pcts = run_case(mp, n, fec=fec)
        ok = worst >= PASS_PCT and mis == 0
        npass, nfail = npass + ok, nfail + (not ok)
        print("  %s FEC=%-3s %-20s N=%d  최저 %5.1f%%  오배송 %d  %s"
              % ("✓" if ok else "✗", "on" if fec else "off", mp, n,
                 worst, mis, "" if ok else "← 실패"))
    print("=" * 72)
    print("결과: %d 통과 / %d 실패" % (npass, nfail))
    return 0 if nfail == 0 else 1

if __name__ == "__main__":
    sys.exit(main())
