#!/usr/bin/env python3
"""A stuck log reader must not stop forwarding (v1.4.3, 2026-11-11).

client → relay → server over loopback. The relay's stdout is a pipe or a
stream socket (what journald gives a systemd unit) that nobody reads. The relay
runs at --log-level 5 and is flooded with unauthenticated probes so it writes
far more log than the 64 KB+ buffer holds. Before the fix the relay blocked in
write() and round trips fell to 0; now lines are dropped and counted.

Checks, for stdout = pipe and = socket:
  1. round trips before the flood          50/50
  2. round trips with the reader stuck     ≥ 45/50
  3. after draining, a "[log] N line(s) dropped" note appears
  4. relay still alive
Loopback only, own processes on random ports, stopped by PID.
BIN= selects the binary (BIN=./multi-fec-old for A/B).
"""
import os, socket, subprocess, sys, time

BIN = os.environ.get("BIN", "./multi-fec")
KEY = "lbkey"


def fp(ip="127.0.0.1"):
    s = socket.socket(2, 2); s.bind((ip, 0)); p = s.getsockname()[1]; s.close(); return p


def run(kind):
    SP, WG, RP, CP, DEC = fp(), fp(), fp("127.0.0.2"), fp(), fp()
    dn = open(os.devnull, "w")
    wg = socket.socket(2, 2); wg.bind(("127.0.0.1", WG)); wg.settimeout(0.01)
    dec = socket.socket(2, 2); dec.bind(("127.0.0.1", DEC))
    if kind == "pipe":
        r, w = os.pipe()
        reader, out = r, w
    else:
        a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        reader, out = a, b.fileno()
    procs = []
    srv = subprocess.Popen([BIN, "-s", "-l", f"127.0.0.1:{SP}", "--wg", f"127.0.0.1:{WG}", "-k", KEY],
                           stdout=dn, stderr=dn); procs.append(srv)
    rel = subprocess.Popen([BIN, "-r", "-l", f"127.0.0.2:{RP}", "--route", f"{KEY} 127.0.0.1:{SP}",
                            "--decoy", f"127.0.0.1:{DEC}", "--log-level", "5"],
                           stdout=out, stderr=out); procs.append(rel)
    if kind == "pipe": os.close(w)
    else: b.close()
    cli = subprocess.Popen([BIN, "-c", "-l", f"127.0.0.1:{CP}", "--path", f"127.0.0.1:127.0.0.2:{RP}",
                            "-k", KEY], stdout=dn, stderr=dn); procs.append(cli)
    app = socket.socket(2, 2); app.bind(("127.0.0.1", 0)); app.settimeout(0.01)

    def rt(n=50):
        ok = 0
        for _ in range(n):
            app.sendto(b"X" * 200, ("127.0.0.1", CP))
            t = time.time()
            while time.time() - t < 0.1:
                try:
                    d, a_ = wg.recvfrom(4096); wg.sendto(b"Y" + d[1:], a_)
                except socket.timeout:
                    pass
                try:
                    app.recv(4096); ok += 1; break
                except socket.timeout:
                    pass
        return ok

    def drain():
        data = b""
        if kind == "pipe":
            os.set_blocking(reader, False)
            try:
                while True:
                    c = os.read(reader, 65536)
                    if not c: break
                    data += c
            except BlockingIOError:
                pass
        else:
            reader.setblocking(False)
            try:
                while True:
                    c = reader.recv(65536)
                    if not c: break
                    data += c
            except BlockingIOError:
                pass
        return data

    try:
        time.sleep(2.5)
        before = rt()
        socks = []
        for i in range(3000):
            s = socket.socket(2, 2)
            s.sendto(bytes([0x40]) + os.urandom(60), ("127.0.0.2", RP)); socks.append(s)
            if i % 100 == 99: time.sleep(0.02)
        time.sleep(1)
        stuck = rt()
        drain()
        # one more line after draining so the "dropped" note is written
        for _ in range(50):
            s = socket.socket(2, 2); s.sendto(bytes([0x40]) + os.urandom(60), ("127.0.0.2", RP)); socks.append(s)
        time.sleep(1.0)
        tail = drain()
        alive = rel.poll() is None
        for s in socks: s.close()
        return before, stuck, b"line(s) dropped" in tail, alive
    finally:
        for p in procs:
            if p.poll() is None: p.kill()
            p.wait()
        try:
            os.close(reader) if kind == "pipe" else reader.close()
        except Exception:
            pass


def main():
    if not os.path.exists(BIN):
        print("binary missing:", BIN); return 1
    fails = 0
    for kind in ("pipe", "socket"):
        before, stuck, note, alive = run(kind)
        checks = [("round trips before flood 50/50", before == 50, f"{before}/50"),
                  ("round trips with log reader stuck >= 45/50", stuck >= 45, f"{stuck}/50"),
                  ("'[log] N line(s) dropped' note after drain", note, str(note)),
                  ("relay alive", alive, str(alive))]
        for name, ok, val in checks:
            fails += not ok
            print(f"  {'ok  ' if ok else 'FAIL'} [{kind}] {name}: {val}")
    print(f"\n{8 - fails}/8 passed")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
