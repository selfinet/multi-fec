#!/usr/bin/env python3
"""서버의 동시 클라이언트 상한 실측 (sv1 루프백. 테스트망 무관).

배경: 서버 mud 의 경로 슬롯은 MUD_PATH_MAX=32 이고 식별자는 (local, remote_ip, remote_port)
다. 클라이언트마다 소스 포트가 다르므로 클라이언트 1개 = 슬롯 1개다. 그런데
RELAY_SESSION_MAX 와 SESSION_MAX 는 둘 다 800 이다 — 세 상한이 어긋난다.

방법: 클라이언트를 1개씩 늘리며 매번 그 클라이언트로 왕복을 시도한다.
33번째부터 실패하면 mud 슬롯이 먼저 막히는 것이 확인된다.
"""
import socket, subprocess, time, os, sys, threading

BIN = os.environ.get("BIN", "/home/stevekim/multi-fec/multi-fec")
KEY = "cliffkey"
SPORT, WGPORT, CBASE = 47601, 47602, 47610
N    = int(os.environ.get("N", "36"))
PKTS = 10

procs = []

def spawn(args):
    p = subprocess.Popen([BIN] + args, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)
    procs.append(p); return p

def echo_sink(sock, stop):
    sock.settimeout(0.3)
    while not stop.is_set():
        try:
            d, a = sock.recvfrom(4096); sock.sendto(d, a)
        except socket.timeout: pass
        except OSError: break

def roundtrip(port, n=PKTS):
    f = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); f.settimeout(0.7)
    got = 0
    for i in range(n):
        try:
            f.sendto(b"C%04d" % i + b"x" * 150, ("127.0.0.1", port)); f.recv(4096); got += 1
        except socket.timeout: pass
    f.close(); return got

wg = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
wg.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
wg.bind(("127.0.0.1", WGPORT))
stop = threading.Event()
threading.Thread(target=echo_sink, args=(wg, stop), daemon=True).start()

common = ["-k", KEY, "--mode", "1", "-f", "5:1", "--mtu", "1250", "--log-level", "2"]
spawn(["-s", "-l", f"127.0.0.1:{SPORT}", "--wg", f"127.0.0.1:{WGPORT}"] + common)
time.sleep(1.5)

print(f"MUD_PATH_MAX=32 · 클라이언트를 1→{N} 로 늘리며 각자 왕복 {PKTS} 회")
print(f"{'클라#':<6}{'왕복':<9}{'누적실패':<10}{'판정'}")
first_fail = None
fails = 0
for i in range(1, N + 1):
    cp = CBASE + i
    spawn(["-c", "-l", f"127.0.0.1:{cp}", "--path", f"127.0.0.1:127.0.0.1:{SPORT}"] + common)
    time.sleep(1.1)
    got = roundtrip(cp)
    ok = got >= PKTS * 0.7
    if not ok:
        fails += 1
        if first_fail is None: first_fail = i
    if i <= 3 or i >= 29 or not ok:
        print(f"{i:<6}{f'{got}/{PKTS}':<9}{fails:<10}{'ok' if ok else '✗ 전달 실패'}")

print()
if first_fail:
    print(f"→ **{first_fail} 번째 클라이언트부터 전달 실패.** 서버 mud 슬롯 32 가 먼저 막힌다")
else:
    print(f"→ {N} 개 전부 정상 — 32 상한이 이 경로에서는 발현하지 않는다")

stop.set()
for p in procs:
    p.terminate()
for p in procs:
    try: p.wait(timeout=3)
    except Exception: p.kill()
wg.close()
