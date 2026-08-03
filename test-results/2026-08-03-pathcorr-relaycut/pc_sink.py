#!/usr/bin/env python3
"""pc_sink.py — s.xdn: 경로 상관도 프로브 수집기.

c 가 같은 seq 를 두 경로로 동시에 쏘고, r 의 포워더가 s 로 넘긴다.
여기서는 (path, seq) 도착 여부만 비트맵에 기록한다. 도착 시각은 보지 않는다
— 상관도는 "같은 seq 가 양쪽에서 함께 잃혔는가"만 필요하다.

출력: 종료 시 stdout 에 JSON 한 줄 + --bitmap 지정 시 원시 비트맵 저장.
"""
import argparse, json, socket, struct, sys, time

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=40000)
ap.add_argument("--count", type=int, required=True, help="송신 예정 pair 수")
ap.add_argument("--idle", type=float, default=8.0, help="이 시간 무수신이면 종료(초)")
ap.add_argument("--bitmap", default="")
a = ap.parse_args()

MAGIC = 0x50436F72  # "PCor"

got = [bytearray(a.count), bytearray(a.count)]   # got[path][seq] = 1
dup = [0, 0]
bad = 0
total = 0

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("0.0.0.0", a.port))
s.settimeout(1.0)

sys.stderr.write("[sink] listening :%d count=%d\n" % (a.port, a.count))
sys.stderr.flush()

first = None
last = time.time()
while True:
    try:
        pkt, _ = s.recvfrom(2048)
    except socket.timeout:
        if first is not None and time.time() - last > a.idle:
            break
        continue
    if len(pkt) < 12:
        bad += 1
        continue
    magic, path, seq = struct.unpack_from("!IIi", pkt, 0)
    if magic != MAGIC or path > 1 or seq < 0 or seq >= a.count:
        bad += 1
        continue
    total += 1
    last = time.time()
    if first is None:
        first = last
    if got[path][seq]:
        dup[path] += 1
    else:
        got[path][seq] = 1

rx = [sum(got[0]), sum(got[1])]
# 2x2 분할표: n11 = 양쪽 도착, n10 = A만, n01 = B만, n00 = 양쪽 손실
n11 = n10 = n01 = n00 = 0
g0, g1 = got[0], got[1]
for i in range(a.count):
    x, y = g0[i], g1[i]
    if x and y:
        n11 += 1
    elif x:
        n10 += 1
    elif y:
        n01 += 1
    else:
        n00 += 1

out = {"count": a.count, "rx_a": rx[0], "rx_b": rx[1], "total_pkts": total,
       "dup_a": dup[0], "dup_b": dup[1], "bad": bad,
       "n11": n11, "n10": n10, "n01": n01, "n00": n00}
print(json.dumps(out))

if a.bitmap:
    with open(a.bitmap, "wb") as f:
        f.write(bytes(got[0]))
        f.write(bytes(got[1]))
