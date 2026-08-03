#!/usr/bin/env python3
"""pc_fwd.py — r.xdn: 경로 상관도 프로브 포워더.

.85 / .86 각각에 소켓을 바인딩해 받은 것을 그대로 s 의 sink 로 넘긴다.
실제 릴레이와 같은 자리에서 같은 r→s 구간(gw NAT 경유)을 타게 하는 것이 목적.
소켓을 IP 별로 따로 두는 이유는 실제 relay/relay@b 가 인스턴스 2개인 것과 같다.
"""
import argparse, select, socket, sys

ap = argparse.ArgumentParser()
ap.add_argument("--bind-a", required=True)      # 192.168.100.85:40001
ap.add_argument("--bind-b", required=True)      # 192.168.100.86:40001
ap.add_argument("--upstream", required=True)    # 192.168.200.254:40000
a = ap.parse_args()


def hp(s):
    h, p = s.rsplit(":", 1)
    return (h, int(p))


up = hp(a.upstream)
socks = []
for b in (a.bind_a, a.bind_b):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(hp(b))
    s.setblocking(False)
    socks.append(s)

# 상류 송신은 경로별로 소켓을 분리해 소스 포트가 섞이지 않게 한다
tx = [socket.socket(socket.AF_INET, socket.SOCK_DGRAM) for _ in socks]

sys.stderr.write("[fwd] %s,%s -> %s\n" % (a.bind_a, a.bind_b, a.upstream))
sys.stderr.flush()

n = 0
while True:
    r, _, _ = select.select(socks, [], [], 1.0)
    for i, s in enumerate(socks):
        if s not in r:
            continue
        while True:                       # 준비된 소켓은 비울 때까지 드레인
            try:
                pkt, _src = s.recvfrom(2048)
            except (BlockingIOError, socket.timeout):
                break
            tx[i].sendto(pkt, up)
            n += 1
