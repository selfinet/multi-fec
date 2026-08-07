#!/usr/bin/env python3
"""rt_multi.py — c.xdn: 다중 클라이언트 실토폴로지 다운스트림 검증.

  blaster_i ─▶ client_i ─mud─▶ [relay×2] ─▶ server ─▶ echo ─▶ server ─▶ client_? ─▶ blaster_?

각 blaster 는 자기 태그 `S%02d#%07d` 를 실어 보내고 되돌아온 것을 센다.
- 자기 태그 회수율 = 그 세션의 **왕복(하향 포함) 전달률**
- 남의 태그 수신    = **오배송**(v1.0.2 결함의 직접 신호)

기존 aging_rt_*.py 는 서버 sink 도착분만 봐서 업스트림만 검증했다. 이 결함은
"A 의 패킷이 B 의 경로로 나가 B 가 conv 불일치로 버림" 형태라 업스트림에는
안 나타난다 — 그래서 실토폴로지에서 한 번도 확인된 적이 없었다.
"""
import argparse, os, signal, socket, subprocess, sys, threading, time

BIN = "/usr/sbin/multi-fec-dist"

ap = argparse.ArgumentParser()
ap.add_argument("--sessions", type=int, default=4)
ap.add_argument("--secs", type=float, default=300)
ap.add_argument("--mbps", type=float, default=1.0, help="세션당 각 방향")
ap.add_argument("--size", type=int, default=1200)
ap.add_argument("--src", required=True)
ap.add_argument("--relay-a", required=True)
ap.add_argument("--relay-b", required=True)
ap.add_argument("--key", required=True)
ap.add_argument("--base-port", type=int, default=51861)
ap.add_argument("--mode", default="duplicate")
ap.add_argument("--fec", default="5:1,20:4")
ap.add_argument("--logdir", default="/tmp/rtmulti")
a = ap.parse_args()
os.makedirs(a.logdir, exist_ok=True)

N = a.sessions
LP = [a.base_port + i for i in range(N)]
procs = []
for i in range(N):
    cmd = [BIN, "-c", "-l", "127.0.0.1:%d" % LP[i],
           "--path", "%s:%s" % (a.src, a.relay_a), "--path", "%s:%s" % (a.src, a.relay_b),
           "-k", a.key, "--obfs-mode", "quic", "--auth-interval", "60",
           "--multipath-mode", a.mode, "-f", a.fec, "--fec-timeout", "10",
           "--mode", "1", "--mtu", "1350", "--decode-buf", "2000",
           "--queue-len", "500", "--sock-buf", "4096", "--report", "10", "--log-level", "4"]
    lf = open("%s/client%d.log" % (a.logdir, i), "w")
    procs.append(subprocess.Popen(cmd, stdout=lf, stderr=subprocess.STDOUT))
time.sleep(6)                      # 경로 PROBING → RUNNING

sent = [0] * N
own = [0] * N
foreign = [0] * N          # 남의 태그를 받은 횟수 = 오배송
bad = [0] * N
socks = []
for i in range(N):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    s.bind(("127.0.0.1", 0))
    s.settimeout(0.2)
    socks.append(s)

stop = threading.Event()

def drain(i):
    while not stop.is_set():
        try:
            d, _ = socks[i].recvfrom(65535)
        except socket.timeout:
            continue
        except Exception:
            break
        if len(d) < 11 or d[0:1] != b"S":
            bad[i] += 1; continue
        try:
            sid = int(d[1:3])
        except ValueError:
            bad[i] += 1; continue
        if sid == i:
            own[i] += 1
        else:
            foreign[i] += 1

ths = [threading.Thread(target=drain, args=(i,), daemon=True) for i in range(N)]
for t in ths: t.start()

pps = a.mbps * 1e6 / 8 / a.size
gap = 1.0 / pps
filler = b"x" * max(0, a.size - 11)
end = time.time() + a.secs
nxt = [time.time()] * N
seq = [0] * N
while time.time() < end:
    now = time.time()
    for i in range(N):
        if now >= nxt[i]:
            socks[i].sendto(b"S%02d#%07d" % (i, seq[i]) + filler, ("127.0.0.1", LP[i]))
            seq[i] += 1; sent[i] += 1
            nxt[i] += gap
            if nxt[i] < now - 0.5: nxt[i] = now
    time.sleep(0.0005)

time.sleep(4)                      # 인플라이트 회수
stop.set()
for t in ths: t.join(timeout=2)
for p in procs:
    p.send_signal(signal.SIGTERM)
for p in procs:
    try: p.wait(timeout=5)
    except Exception: p.kill()

print("session,sent,own_back,own_pct,foreign,bad")
for i in range(N):
    pct = own[i] * 100.0 / sent[i] if sent[i] else 0
    print("S%02d,%d,%d,%.3f,%d,%d" % (i, sent[i], own[i], pct, foreign[i], bad[i]))
