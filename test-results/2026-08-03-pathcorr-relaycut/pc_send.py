#!/usr/bin/env python3
"""pc_send.py — c.xdn: 경로 상관도 프로브 송신기.

같은 seq 를 두 경로로 **연속 두 번** 쏜다. 두 사본이 같은 순간의 네트워크
상태를 겪게 하려는 것이라 사이에 sleep 을 넣지 않는다.

주의: netem 필터가 dport 를 매치하므로, 프로브 포트가 임시 tc 필터로
band 1:1 / 1:2 에 분류돼 있어야 실제 경로와 같은 임피어먼트를 받는다.
pc_setup.sh 가 그 필터를 넣고 뺀다.
"""
import argparse, socket, struct, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--dest-a", required=True)      # 192.168.100.85:40001
ap.add_argument("--dest-b", required=True)      # 192.168.100.86:40001
ap.add_argument("--src", default="192.168.100.141")
ap.add_argument("--pps", type=int, default=500, help="경로당 pps")
ap.add_argument("--secs", type=float, default=600)
ap.add_argument("--size", type=int, default=1200)
a = ap.parse_args()

MAGIC = 0x50436F72


def hp(s):
    h, p = s.rsplit(":", 1)
    return (h, int(p))


da, db = hp(a.dest_a), hp(a.dest_b)
pad = bytes(max(0, a.size - 12))

# 경로마다 소켓을 분리 — 실제 mud 는 소켓 하나지만, 여기서는 커널 송신 큐가
# 한쪽에 몰려 인위적 상관을 만드는 것을 피하는 쪽이 중요하다.
sa = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sb = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
for s in (sa, sb):
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
    s.bind((a.src, 0))

total = int(a.pps * a.secs)
interval = 1.0 / a.pps
t0 = time.perf_counter()
sent = 0
for seq in range(total):
    hdr_a = struct.pack("!IIi", MAGIC, 0, seq)
    hdr_b = struct.pack("!IIi", MAGIC, 1, seq)
    try:
        sa.sendto(hdr_a + pad, da)
        sb.sendto(hdr_b + pad, db)
        sent += 1
    except OSError as e:
        sys.stderr.write("send error at %d: %s\n" % (seq, e))
    nxt = t0 + (seq + 1) * interval
    d = nxt - time.perf_counter()
    if d > 0:
        time.sleep(d)

el = time.perf_counter() - t0
sys.stderr.write("[send] pairs=%d elapsed=%.1fs actual_pps=%.1f\n"
                 % (sent, el, sent / el))
print(total)
