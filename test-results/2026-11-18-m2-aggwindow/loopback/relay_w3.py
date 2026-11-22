#!/usr/bin/env python3
"""Loopback check: client --workers 3 -> 2 paths x 3 relay instances -> server --workers 3 -> UDP echo (WG stand-in).
Everything on 127.0.0.x, nothing leaves the host. Usage: relay_w3.py BIN [scenario]
scenarios: basic (2 paths), cutpath (kill path B relays mid-run), direct (no relay, reference)."""
import os, socket, subprocess, sys, time, signal, threading, struct

BIN = os.path.abspath(sys.argv[1]); SC = sys.argv[2] if len(sys.argv) > 2 else "basic"
D = os.path.dirname(os.path.abspath(__file__)); KEY = "relaytest-key-123"
SRV, WG, CL = 41500, 41820, 41821
RA, RB = ("127.0.0.2", 42500), ("127.0.0.3", 42500)
procs = []

def start(name, args):
    log = open(os.path.join(D, name + ".log"), "w")
    p = subprocess.Popen(["timeout", "300", BIN] + args, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    procs.append((name, p)); return p

def echo():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", WG)); s.settimeout(0.5)
    while not stop.is_set():
        try: d, a = s.recvfrom(4096); s.sendto(d, a)
        except socket.timeout: pass
stop = threading.Event(); threading.Thread(target=echo, daemon=True).start()

common = ["-k", KEY, "--report", "5", "--log-level", "4", "--multipath-mode", "aggregate"]
start("server", ["-s", "-l", f"127.0.0.1:{SRV}", "--wg", f"127.0.0.1:{WG}", "--workers", "3"] + common)
if SC != "direct":
    for tag, (ip, p) in (("A", RA), ("B", RB)):
        for k in range(3):
            start(f"relay{tag}{k}", ["-r", "-l", f"{ip}:{p+k}", "--upstream", f"127.0.0.1:{SRV+k}", "-k", KEY, "--log-level", "4"])
    paths = ["--path", f"{RA[0]}:{RA[1]}", "--path", f"{RB[0]}:{RB[1]}"]
else:
    paths = ["--path", f"127.0.0.1:{SRV}"]
time.sleep(1)
start("client", ["-c", "-l", f"127.0.0.1:{CL}", "--workers", "3"] + paths + common)
time.sleep(4)

c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.bind(("127.0.0.1", 0)); c.settimeout(0.01)
N = 6000; got = set(); sent = 0; t0 = time.time(); cut_done = False
for i in range(N):
    c.sendto(struct.pack("!I", i) + os.urandom(996), ("127.0.0.1", CL)); sent += 1
    if SC == "cutpath" and not cut_done and i == N // 2:
        for name, p in procs:
            if name.startswith("relayB"): os.killpg(p.pid, signal.SIGKILL)
        cut_done = True; print("  path B relays killed at", i)
    try:
        while True: got.add(struct.unpack("!I", c.recv(2048)[:4])[0])
    except (socket.timeout, BlockingIOError): pass
    time.sleep(0.001)
end = time.time() + 3
while time.time() < end:
    try: got.add(struct.unpack("!I", c.recv(2048)[:4])[0])
    except socket.timeout: pass
half = N // 2
first = sum(1 for i in got if i < half); second = sum(1 for i in got if i >= half)
print(f"{SC}: sent {sent} echoed {len(got)} ({100*len(got)/N:.2f}%)  first half {first}/{half}  second half {second}/{N-half}")
alive = [(n, p.poll()) for n, p in procs]
print("  exited early:", [n for n, rc in alive if rc is not None and not (SC == 'cutpath' and n.startswith('relayB'))] or "none")
stop.set()
for n, p in procs:
    try: os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError: pass
time.sleep(1)
