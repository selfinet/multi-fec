#!/usr/bin/env python3
"""rt_echo.py — s.xdn: multi-fec 서버의 --wg 목적지에서 받은 것을 그대로 되돌려준다.

되돌릴 때 **받은 주소 그대로** 로 보내는 것이 핵심이다. multi-fec 서버는 conv 마다
별도 소켓으로 wg 에 포워딩하므로, 그 소켓 주소로 답하면 서버가 해당 conv →
해당 클라이언트 세션으로 하향 전달한다. 즉 이 echo 가 다운스트림 경로를 구동한다.
"""
import socket, sys, signal
port = int(sys.argv[1])
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 8 << 20)
s.bind(("127.0.0.1", port))
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
n = 0
while True:
    try:
        d, a = s.recvfrom(65535)
    except Exception:
        break
    s.sendto(d, a)
    n += 1
