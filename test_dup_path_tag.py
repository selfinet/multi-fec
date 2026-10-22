#!/usr/bin/env python3
"""
test_dup_path_tag.py — duplicate 모드에서 서버 하향이 두 경로를 모두 쓰는지 (sv1 루프백 전용)

서버는 데이터가 도착한 경로에만 세션 태그를 붙여 하향을 그 경로들로 제한한다. duplicate 에서
늘 늦게 오는 사본은 dedup 으로 버려져 데이터로 세지지 않으므로, 그 경로는 태그되지 않고 하향에서
빠졌다(1.4.0, 2026-10-23 발견). 루프백 두 경로는 지연이 같고 client 가 path[0] 에 먼저 보내므로
path[1] 사본이 늘 두 번째다 — 수정 전에는 client path[1] rx 가 probe 뿐(~500)이었다.

판정: 35초 양방향 ~2000 pps 후 client 경로 보고에서 path[1] rx ≥ path[0] rx × 0.5, 왕복 손실 0.
  BIN=./multi-fec SBIN=<server 바이너리> python3 test_dup_path_tag.py
"""
import os, re, socket, subprocess, sys, tempfile, threading, time

BIN  = os.environ.get("BIN", "./multi-fec")
SBIN = os.environ.get("SBIN", BIN)
DUR  = float(os.environ.get("DUR", "35"))   # client 경로 보고가 ~30초마다라 30초 넘게 돌린다
SP, WP, LP = 47543, 47920, 47921

def main():
    tmp = tempfile.mkdtemp(prefix="duptag_")
    srv_log, cli_log = os.path.join(tmp, "srv.log"), os.path.join(tmp, "cli.log")
    srv = subprocess.Popen([SBIN, "-s", "-l", "127.0.0.1:%d" % SP, "--wg", "127.0.0.1:%d" % WP,
                            "-k", "duptag", "--multipath-mode", "duplicate"],
                           stdout=open(srv_log, "w"), stderr=subprocess.STDOUT)
    cli = subprocess.Popen([BIN, "-c", "-l", "127.0.0.1:%d" % LP,
                            "--path", "127.0.0.1:127.0.0.1:%d" % SP,
                            "--path", "127.0.0.2:127.0.0.1:%d" % SP,
                            "-k", "duptag", "--multipath-mode", "duplicate"],
                           stdout=open(cli_log, "w"), stderr=subprocess.STDOUT)
    sink = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sink.bind(("127.0.0.1", WP)); sink.settimeout(0.5)
    up = [0]; stop = [False]
    def echo():
        while not stop[0]:
            try: d, a = sink.recvfrom(4096)
            except socket.timeout: continue
            up[0] += 1; sink.sendto(d, a)
    threading.Thread(target=echo, daemon=True).start()
    g = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    g.bind(("127.0.0.1", 0)); g.setblocking(False)
    g.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    def drain():
        n = 0
        while True:
            try: g.recv(4096); n += 1
            except BlockingIOError: return n
    time.sleep(1.5)
    sent = down = 0; pay = os.urandom(1200); t0 = time.time()
    try:
        while time.time() - t0 < DUR:
            for _ in range(8):
                g.sendto(sent.to_bytes(8, "little") + pay[:1192], ("127.0.0.1", LP)); sent += 1
            time.sleep(0.004)
            down += drain()
        time.sleep(1); down += drain()
    finally:
        stop[0] = True
        srv.terminate(); cli.terminate(); srv.wait(); cli.wait()

    rx = {}
    for line in open(cli_log, errors="replace"):
        m = re.search(r"path\[(\d)\] \S+ .* rx=(\d+)", re.sub(r"\x1b\[[0-9;]*m", "", line))
        if m: rx[int(m.group(1))] = int(m.group(2))
    print("sent %d · 상향 %d · 하향 %d · client rx path[0]=%s path[1]=%s"
          % (sent, up[0], down, rx.get(0), rx.get(1)))
    ok = (0 in rx and 1 in rx and rx[1] >= rx[0] * 0.5 and up[0] == sent and down == sent)
    print("결과: %s" % ("통과 ✓" if ok else "실패 ✗ (로그 %s)" % tmp))
    return 0 if ok else 1

if __name__ == "__main__":
    sys.exit(main())
