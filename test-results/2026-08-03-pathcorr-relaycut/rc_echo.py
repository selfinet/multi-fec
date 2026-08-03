#!/usr/bin/env python3
"""rc_echo.py — s.xdn: WG 터널 안쪽 UDP 에코.

릴레이 단절 테스트는 실제 운영 체인(c → multi-fec → relay×2 → server → WG)을
그대로 타야 의미가 있다. 그래서 별도 테스트 체인을 만들지 않고 WG 터널
`starlink-fec`(s=10.9.10.1) 위에서 왕복시킨다.
"""
import argparse, socket

ap = argparse.ArgumentParser()
ap.add_argument("--bind", default="10.9.10.1:40010")
a = ap.parse_args()
h, p = a.bind.rsplit(":", 1)

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind((h, int(p)))
print("[echo] %s" % a.bind, flush=True)
while True:
    pkt, src = s.recvfrom(2048)
    s.sendto(pkt, src)
