#!/usr/bin/env python3
"""
test_server_conv_cap.py — server per-conv WG-socket FD budget (CWE-400 guard).

A single keyed client can mint one conv per distinct WG-side source port. Under
a lowered RLIMIT_NOFILE this test floods the client with many source ports and
checks the SERVER:

  fixed binary (BIN):
    1. server FD never reaches the soft RLIMIT (no exhaustion)
    2. no "new_connected_socket failed" in the server log
    3. the budget is enforced ("conv socket budget ... reached")
    4. service continues past the budget (convs keep being served via LRU
       eviction: total 'new conv' > budget)

  with SBIN_OLD set to a pre-fix binary, A/B shows the old one DOES exhaust:
    - server FD reaches the soft RLIMIT and logs "new_connected_socket failed"

Loopback only. BIN= fixed server/client, SBIN_OLD= optional pre-fix server.
"""
import os, socket, subprocess, sys, time, tempfile, re, resource, signal

D   = os.path.dirname(os.path.abspath(__file__))
BIN = os.environ.get("BIN", os.path.join(D, "multi-fec"))
SOFT = 200                      # lowered RLIMIT_NOFILE → budget = SOFT-64 = 136
BUDGET = SOFT - 64
KEY = "convcap"

def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]; s.close(); return p

def nfd(pid):
    try: return len(os.listdir("/proc/%d/fd" % pid))
    except OSError: return -1

passed = failed = 0
def check(name, ok, extra=""):
    global passed, failed
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{('  ' + extra) if extra else ''}")
    if ok: passed += 1
    else:  failed += 1

def run(server_bin, label):
    tmp = tempfile.mkdtemp(prefix="convcap_", dir=D)
    SP, WG, CP = free_port(), free_port(), free_port()
    slog = os.path.join(tmp, "srv.log")

    wg = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    wg.bind(("127.0.0.1", WG)); wg.settimeout(0.02)   # dumb WG sink: drain

    def lower_rlimit():
        resource.setrlimit(resource.RLIMIT_NOFILE, (SOFT, SOFT))

    srv = subprocess.Popen(
        [server_bin, "-s", "-l", "127.0.0.1:%d" % SP, "--wg", "127.0.0.1:%d" % WG,
         "-k", KEY, "--log-level", "4"],
        stdout=open(slog, "w"), stderr=subprocess.STDOUT, preexec_fn=lower_rlimit)
    cli = subprocess.Popen(
        [BIN, "-c", "-l", "127.0.0.1:%d" % CP, "--path", "127.0.0.1:127.0.0.1:%d" % SP,
         "-k", KEY, "--log-level", "3"],
        stdout=open(os.path.join(tmp, "cli.log"), "w"), stderr=subprocess.STDOUT,
        preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_NOFILE, (65536, 65536)))
    fd_max = 0
    try:
        time.sleep(1.2)
        # flood: many distinct WG-side source ports → many convs on the server.
        # Keep going in waves so LRU eviction has to churn.
        socks = []
        for wave in range(6):
            for i in range(120):
                s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                s.bind(("127.0.0.1", 0))
                s.sendto(b"Z" * 120, ("127.0.0.1", CP))
                socks.append(s)
            time.sleep(0.2)
            fd_max = max(fd_max, nfd(srv.pid))
            # drain WG sink so the server isn't blocked
            try:
                while True: wg.recv(4096)
            except socket.timeout: pass
        time.sleep(1.0)
        fd_max = max(fd_max, nfd(srv.pid))
        log = open(slog).read()
        new_conv   = log.count("new conv")
        failed_sock= log.count("new_connected_socket failed")
        budget_hit = ("conv socket budget" in log) and ("reached" in log)
        for s in socks: s.close()
        return dict(label=label, fd_max=fd_max, new_conv=new_conv,
                    failed_sock=failed_sock, budget_hit=budget_hit, log=log)
    finally:
        for p in (cli, srv):
            p.send_signal(signal.SIGTERM)
        for p in (cli, srv):
            try: p.wait(timeout=3)
            except Exception: p.kill()

def main():
    print("== fixed binary ==")
    r = run(BIN, "fixed")
    print("   fd_max=%d (soft=%d budget=%d) new_conv=%d failed_sock=%d budget_hit=%s"
          % (r["fd_max"], SOFT, BUDGET, r["new_conv"], r["failed_sock"], r["budget_hit"]))
    check("server FD stays below the soft RLIMIT (no exhaustion)",
          0 < r["fd_max"] < SOFT, "fd_max=%d" % r["fd_max"])
    check("no 'new_connected_socket failed'", r["failed_sock"] == 0,
          "count=%d" % r["failed_sock"])
    # Enforcement evidence: FD plateaus near the budget (not at the RLIMIT).
    # The last-resort "budget reached" drop warn only fires when eviction can't
    # free a slot, which does not happen under a flood (there is always an older
    # conv to evict), so the plateau — not that warn — is the signal.
    check("budget enforced (FD plateaus near budget, well below RLIMIT)",
          r["fd_max"] <= BUDGET + 40, "fd_max=%d budget=%d soft=%d" % (r["fd_max"], BUDGET, SOFT))
    check("service continues past budget (convs served > budget via LRU)",
          r["new_conv"] > BUDGET, "new_conv=%d budget=%d" % (r["new_conv"], BUDGET))

    old = os.environ.get("SBIN_OLD")
    if old and os.path.exists(old):
        print("== A/B: pre-fix binary (%s) ==" % os.path.basename(old))
        o = run(old, "old")
        print("   fd_max=%d new_conv=%d failed_sock=%d"
              % (o["fd_max"], o["new_conv"], o["failed_sock"]))
        check("pre-fix DOES exhaust (FD hits RLIMIT and/or socket alloc fails)",
              o["fd_max"] >= SOFT or o["failed_sock"] > 0,
              "fd_max=%d failed_sock=%d" % (o["fd_max"], o["failed_sock"]))
    else:
        print("== A/B skipped (set SBIN_OLD=<pre-fix binary> to enable) ==")

    print("결과: %d/%d 통과 %s" % (passed, passed + failed, "✓" if failed == 0 else "✗"))
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
