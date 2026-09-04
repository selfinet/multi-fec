#!/usr/bin/env python3
"""rt_echo_ip.py — 지정한 IP:port 에 바인딩해 받은 것을 그대로 되돌린다.
WG 다중 세션 시험용: 세션마다 자기 터널 주소(10.9.2X.1)에 하나씩 띄운다.
rt_echo.py 와 달리 **바인딩 주소를 받는다** — 127.0.0.1 에 묶으면 WG 를 안 탄다."""
import socket, sys, signal
ip, port = sys.argv[1], int(sys.argv[2])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
s.bind((ip, port))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
while True:
    try:
        d, a = s.recvfrom(65535)
    except Exception:
        break
    s.sendto(d, a)
