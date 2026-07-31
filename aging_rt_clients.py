#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""aging_rt_clients.py — 실제 토폴로지 10세션 아징: 클라이언트+생성기 측 (c.xdn에서 실행)

multi-fec 테스트 클라이언트 N개를 각자 다른 로컬 포트로 띄우고(=세션 N개),
각 클라이언트 listen 포트로 태그(S%02d#seq) UDP를 rate pkt/s로 흘린다.
경로는 릴레이 1개(--relay IP:PORT). DURATION 후 자동 종료, 송신 카운트 기록.
"""
import argparse, os, socket, subprocess, sys, threading, time

BIN = "/usr/sbin/multi-fec-dist"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", required=True)
    ap.add_argument("--duration", type=float, required=True)
    ap.add_argument("--sessions", type=int, default=10)
    ap.add_argument("--rate", type=int, default=50, help="pkt/s/session")
    ap.add_argument("--relay", required=True, help="릴레이 IP:PORT")
    ap.add_argument("--src", required=True, help="클라이언트 소스 IP")
    ap.add_argument("--key", required=True)
    ap.add_argument("--fec", default="20:5")
    ap.add_argument("--mtu", type=int, default=1350)
    ap.add_argument("--base-port", type=int, default=51840)
    ap.add_argument("--warmup", type=float, default=4.0)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    n = a.sessions
    rip, rport = a.relay.rsplit(":", 1)
    payload_sz = max(64, a.mtu - 200)

    procs = []
    lports = []
    for i in range(n):
        lp = a.base_port + i
        lports.append(lp)
        cmd = [BIN, "-c", "-l", "127.0.0.1:%d" % lp,
               "--path", "%s:%s:%s" % (a.src, rip, rport),
               "-k", a.key, "--obfs-mode", "quic", "--auth-interval", "60",
               "--multipath-mode", "failover",
               "-f", a.fec, "--fec-timeout", "5", "--mode", a.mode,
               "--mtu", str(a.mtu), "--decode-buf", "8000", "--queue-len", "500",
               "--sock-buf", "4096", "--log-level", "2"]
        procs.append(subprocess.Popen(cmd, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL))

    time.sleep(a.warmup)
    alive_after_start = sum(1 for p in procs if p.poll() is None)

    sent = [0] * n
    stop = threading.Event()

    def blaster(idx, lp):
        tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        interval = 1.0 / a.rate if a.rate > 0 else 0
        body = bytes((j & 0xFF) for j in range(payload_sz - 12))
        seq = 0
        while not stop.is_set():
            hdr = ("S%02d#%08d|" % (idx, seq)).encode()
            try:
                tx.sendto(hdr + body, ("127.0.0.1", lp))
            except OSError:
                pass
            seq += 1; sent[idx] = seq
            if interval:
                time.sleep(interval)
        tx.close()

    threads = [threading.Thread(target=blaster, args=(i, lports[i])) for i in range(n)]
    for t in threads:
        t.start()

    out = open(a.out, "w", buffering=1)
    out.write("### RT-AGING clients mode=%s sessions=%d rate=%d dur=%.0fs relay=%s ###\n"
              % (a.mode, n, a.rate, a.duration, a.relay))
    out.write("clients_alive_after_start=%d/%d\n" % (alive_after_start, n))

    start = time.monotonic(); end = start + a.duration
    while time.monotonic() < end:
        time.sleep(min(60.0, max(0.0, end - time.monotonic())))
        alive = sum(1 for p in procs if p.poll() is None)
        out.write("t=%.0f clients_alive=%d/%d sent_total=%d\n"
                  % (time.monotonic() - start, alive, n, sum(sent)))

    stop.set()
    for t in threads:
        t.join()
    cli_alive_end = sum(1 for p in procs if p.poll() is None)
    for p in procs:
        p.terminate()
    for p in procs:
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired: p.kill()

    out.write("### RESULT mode=%s ###\n" % a.mode)
    out.write("sent_total=%d clients_alive_end=%d/%d\n"
              % (sum(sent), cli_alive_end, n))
    out.write("per_session_sent=%s\n" % sent)
    out.close()
    print("clients done mode=%s sent=%d alive_end=%d/%d"
          % (a.mode, sum(sent), cli_alive_end, n))


if __name__ == "__main__":
    main()
