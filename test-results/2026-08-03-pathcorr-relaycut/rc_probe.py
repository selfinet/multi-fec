#!/usr/bin/env python3
"""rc_probe.py — c.xdn: 릴레이 단절 중 왕복 전달률·RTT 를 100ms 버킷으로 기록.

송신 스레드가 고정 pps 로 seq+송신시각을 실어 보내고, 수신 스레드가 돌아온
것을 센다. 절체 구간을 보려면 평균이 아니라 **시간축**이 필요하므로 버킷별로
sent / recv / rtt 를 남긴다.

출력 CSV: t_ms,sent,recv,rtt_p50_us,rtt_max_us
버킷은 **송신 시각** 기준이다. 늦게 돌아온 응답도 원래 버킷에 귀속시켜야
"그 시점에 보낸 것 중 몇 개가 살아 돌아왔나"가 된다.
"""
import argparse, socket, struct, sys, threading, time

ap = argparse.ArgumentParser()
ap.add_argument("--dest", default="10.9.10.1:40010")
ap.add_argument("--pps", type=int, default=200)
ap.add_argument("--secs", type=float, default=180)
ap.add_argument("--size", type=int, default=1000)
ap.add_argument("--bucket-ms", type=int, default=100)
ap.add_argument("--out", required=True)
ap.add_argument("--drain", type=float, default=3.0, help="송신 후 회수 대기(초)")
a = ap.parse_args()

h, p = a.dest.rsplit(":", 1)
dest = (h, int(p))
MAGIC = 0x52436574   # "RCet"

NB = int(a.secs * 1000 / a.bucket_ms) + 2
sent_b = [0] * NB
recv_b = [0] * NB
rtts = [[] for _ in range(NB)]

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
s.settimeout(0.3)

pad = bytes(max(0, a.size - 16))
stop = threading.Event()
t0 = time.perf_counter()
t0_wall = time.time()          # 절단 시각과 t_ms 축을 맞추기 위한 기준점
sys.stderr.write("[probe] t0_wall=%.6f\n" % t0_wall)
sys.stderr.flush()


def rx():
    while not stop.is_set():
        try:
            pkt, _ = s.recvfrom(2048)
        except socket.timeout:
            continue
        except OSError:
            break
        if len(pkt) < 16:
            continue
        magic, seq, tx_us = struct.unpack_from("!IIQ", pkt, 0)
        if magic != MAGIC:
            continue
        now_us = int((time.perf_counter() - t0) * 1e6)
        b = int(tx_us // (a.bucket_ms * 1000))
        if 0 <= b < NB:
            recv_b[b] += 1
            rtts[b].append(now_us - tx_us)


th = threading.Thread(target=rx, daemon=True)
th.start()

interval = 1.0 / a.pps
total = int(a.pps * a.secs)
for seq in range(total):
    tx_us = int((time.perf_counter() - t0) * 1e6)
    b = int(tx_us // (a.bucket_ms * 1000))
    try:
        s.sendto(struct.pack("!IIQ", MAGIC, seq, tx_us) + pad, dest)
        if 0 <= b < NB:
            sent_b[b] += 1
    except OSError:
        pass
    nxt = t0 + (seq + 1) * interval
    d = nxt - time.perf_counter()
    if d > 0:
        time.sleep(d)

time.sleep(a.drain)          # 늦게 돌아오는 것 회수
stop.set()
th.join(timeout=2)

with open(a.out, "w") as f:
    f.write("# t0_wall=%.6f pps=%d secs=%g\n" % (t0_wall, a.pps, a.secs))
    f.write("t_ms,sent,recv,rtt_p50_us,rtt_max_us\n")
    for i in range(NB):
        if sent_b[i] == 0 and recv_b[i] == 0:
            continue
        r = sorted(rtts[i])
        p50 = r[len(r) // 2] if r else -1
        mx = r[-1] if r else -1
        f.write("%d,%d,%d,%d,%d\n" % (i * a.bucket_ms, sent_b[i], recv_b[i], p50, mx))

ts, tr = sum(sent_b), sum(recv_b)
sys.stderr.write("[probe] sent=%d recv=%d loss=%.4f%%\n"
                 % (ts, tr, 100.0 * (ts - tr) / ts if ts else 0))
