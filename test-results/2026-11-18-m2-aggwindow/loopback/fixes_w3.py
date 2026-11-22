#!/usr/bin/env python3
"""Loopback checks for the 2026-11-23 mt.1 fixes. 127.0.0.x only. Usage: fixes_w3.py BIN {allcut|twoclient|exitcode}"""
import os, socket, subprocess, sys, time, signal, threading, struct

BIN = os.path.abspath(sys.argv[1]); SC = sys.argv[2]
D = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fx_" + SC); os.makedirs(D, exist_ok=True)
KEY = "relaytest-key-123"; SRV, WG = 43500, 43820
common = ["-k", KEY, "--report", "5", "--log-level", "4", "--multipath-mode", "aggregate"]
procs = {}

def start(name, args, wrap=True):
    log = open(os.path.join(D, name + ".log"), "a")
    cmd = (["timeout", "300"] if wrap else []) + [BIN] + args
    p = subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    procs[name] = p; return p

def killg(name, sig=signal.SIGKILL):
    try: os.killpg(procs[name].pid, sig)
    except ProcessLookupError: pass

stop = threading.Event()
def echo():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", WG)); s.settimeout(0.2)
    while not stop.is_set():
        try: d, a = s.recvfrom(4096); s.sendto(d, a)
        except socket.timeout: pass

def cleanup():
    stop.set()
    for n in list(procs): killg(n, signal.SIGTERM)
    time.sleep(1)
    for n in list(procs): killg(n, signal.SIGKILL)

def grep(name, pat):
    try: return [l for l in open(os.path.join(D, name + ".log"), errors="replace") if pat in l]
    except FileNotFoundError: return []

if SC == "allcut":
    threading.Thread(target=echo, daemon=True).start()
    start("server", ["-s", "-l", f"127.0.0.1:{SRV}", "--wg", f"127.0.0.1:{WG}", "--workers", "3"] + common)
    rel = {}
    for tag, ip in (("A", "127.0.0.2"), ("B", "127.0.0.3")):
        for k in range(3):
            rel[f"relay{tag}{k}"] = ["-r", "-l", f"{ip}:{44500+k}", "--upstream", f"127.0.0.1:{SRV+k}", "-k", KEY, "--log-level", "4"]
    for n, a in rel.items(): start(n, a)
    time.sleep(1)
    start("client", ["-c", "-l", "127.0.0.1:43821", "--workers", "3", "--path", "127.0.0.2:44500", "--path", "127.0.0.3:44500"] + common)
    time.sleep(4)
    c = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); c.bind(("127.0.0.1", 0)); c.setblocking(False)
    sent_t, recv_t = {}, {}
    def pump(until):
        while True:
            try:
                d = c.recv(2048); i = struct.unpack("!I", d[:4])[0]
                recv_t.setdefault(i, time.time())
            except BlockingIOError: break
    i = 0; t0 = time.time(); cut_at = restore_at = None
    while time.time() - t0 < 16:
        now = time.time() - t0
        if cut_at is None and now >= 4:
            for n in rel: killg(n)
            cut_at = time.time(); print(f"  cut both paths at t={now:.1f}s")
        if restore_at is None and now >= 9:
            for n, a in rel.items(): start(n, a)
            restore_at = time.time(); print(f"  restored at t={now:.1f}s")
        c.sendto(struct.pack("!I", i) + os.urandom(496), ("127.0.0.1", 43821)); sent_t[i] = time.time(); i += 1
        pump(0); time.sleep(0.002)
    end = time.time() + 3
    while time.time() < end: pump(0); time.sleep(0.01)
    during = [k for k, t in sent_t.items() if cut_at <= t < restore_at]
    late = [k for k in during if k in recv_t]
    stale = [k for k in recv_t if recv_t[k] - sent_t[k] > 1.5]
    after = [k for k, t in sent_t.items() if t >= restore_at + 3]
    print(f"allcut: sent {i}, during outage {len(during)} → delivered later {len(late)}; "
          f"delivered >1.5 s after send: {len(stale)} (max {max([recv_t[k]-sent_t[k] for k in recv_t] or [0]):.2f} s); "
          f"after restore+3s {sum(1 for k in after if k in recv_t)}/{len(after)}")
    for l in grep("client", "RUNNING again")[:3] + grep("server", "RUNNING again")[:3]: print("  " + l.strip()[-150:])
    cleanup()

elif SC == "twoclient":
    threading.Thread(target=echo, daemon=True).start()
    start("server", ["-s", "-l", f"127.0.0.1:{SRV}", "--wg", f"127.0.0.1:{WG}", "--workers", "3"] + common)
    time.sleep(1)
    start("c1", ["-c", "-l", "127.0.0.1:43831", "--workers", "3", "--path", f"127.0.0.1:{SRV}"] + common)
    time.sleep(3)
    start("c2", ["-c", "-l", "127.0.0.1:43832", "--workers", "3", "--path", f"127.0.0.1:{SRV}"] + common)
    time.sleep(3)
    s1 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s1.bind(("127.0.0.1", 0)); s1.setblocking(False)
    s2 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s2.bind(("127.0.0.1", 0)); s2.setblocking(False)
    def phase(secs, use1, use2):
        g1, g2, n = set(), set(), 0; t0 = time.time()
        while time.time() - t0 < secs:
            if use1: s1.sendto(struct.pack("!I", n) + b"x" * 300, ("127.0.0.1", 43831))
            if use2: s2.sendto(struct.pack("!I", n) + b"y" * 300, ("127.0.0.1", 43832))
            n += 1; time.sleep(0.003)
            for s, g in ((s1, g1), (s2, g2)):
                try:
                    while True: g.add(struct.unpack("!I", s.recv(2048)[:4])[0])
                except BlockingIOError: pass
        time.sleep(1)
        for s, g in ((s1, g1), (s2, g2)):
            try:
                while True: g.add(struct.unpack("!I", s.recv(2048)[:4])[0])
            except BlockingIOError: pass
        return n, len(g1), len(g2)
    n, a, b = phase(8, True, True)
    print(f"twoclient both live 8 s: sent {n} each → c1 {a} ({100*a/n:.1f}%)  c2 {b} ({100*b/n:.1f}%)")
    print(f"  server 'conv replaced' lines {len(grep('server','replaced'))}, 'refused' warn lines {len(grep('server','refused'))}, 'new conv' {len(grep('server','new conv'))}")
    killg("c1"); t_kill = time.time()
    n, a, b = phase(10, False, True)
    print(f"twoclient after c1 killed, 10 s: c2 {b}/{n} ({100*b/n:.1f}%)")
    print(f"  server 'conv replaced' lines now {len(grep('server','replaced'))}")
    cleanup()

elif SC == "exitcode":
    for how in ("group-SIGTERM", "worker-SIGKILL", "supervisor-SIGTERM"):
        p = start("srv_" + how, ["-s", "-l", f"127.0.0.1:{SRV}", "--wg", f"127.0.0.1:{WG}", "--workers", "3"] + common, wrap=False)
        time.sleep(2)
        kids = subprocess.run(["pgrep", "-P", str(p.pid)], capture_output=True, text=True).stdout.split()
        if how == "group-SIGTERM": os.killpg(p.pid, signal.SIGTERM)          # what `systemctl stop` does (cgroup)
        elif how == "worker-SIGKILL": os.kill(int(kids[1]), signal.SIGKILL)   # a worker dies on its own
        else: os.kill(p.pid, signal.SIGTERM)                                  # only the supervisor
        try: rc = p.wait(10)
        except subprocess.TimeoutExpired: rc = "hang"; killg("srv_" + how)
        left = subprocess.run(["pgrep", "-f", f"127.0.0.1:{SRV} --wg"], capture_output=True, text=True).stdout.split()
        print(f"exitcode {how}: workers {len(kids)}, supervisor exit {rc}, leftover {len(left)}")
        time.sleep(1)
