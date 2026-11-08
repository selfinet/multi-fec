#!/usr/bin/env python3
"""
test_relay_traffic_log.py — relay traffic accounting + fingerprint + flood safety.

Verifies v1.4.2 relay traffic logging:
  1. periodic [relay][report] info line appears with up=/down=/live=
  2. up and down byte/packet counters move under real traffic
  3. per-session debug line identifies the client by fingerprint (cf:...),
     and that fingerprint matches `--fingerprint-ip <ip>` with the same salt
  4. flood safety: a burst of unauthenticated garbage does NOT flood the log
     (per-event logs are debug/counters) and is counted as probe=N
  5. no raw client IP in the "new session" line (it uses cf:)

Loopback only. BIN= overrides binary.
"""
import os, socket, subprocess, sys, time, tempfile, re, signal

D   = os.path.dirname(os.path.abspath(__file__))
BIN = os.environ.get("BIN", os.path.join(D, "multi-fec"))
KEY = "traflog"

def free_port():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]; s.close(); return p

passed = failed = 0
def check(name, ok, extra=""):
    global passed, failed
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}{('  ' + extra) if extra else ''}")
    if ok: passed += 1
    else:  failed += 1

def main():
    tmp = tempfile.mkdtemp(prefix="traflog_", dir=D)
    salt = os.path.join(tmp, "salt")
    env = dict(os.environ, MF_LOG_SALT_FILE=salt)
    RP, SINK, CP, WG = free_port(), free_port(), free_port(), free_port()
    rlog = os.path.join(tmp, "relay.log")

    # dumb upstream sink: receive (uplink) + echo back (downlink)
    sink = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sink.bind(("127.0.0.1", SINK)); sink.settimeout(0.05)

    relay = subprocess.Popen(
        [BIN, "-r", "-l", "127.0.0.1:%d" % RP, "-k", KEY,
         "--upstream", "127.0.0.1:%d" % SINK, "--report", "1", "--log-level", "5"],
        stdout=open(rlog, "w"), stderr=subprocess.STDOUT, env=env)
    client = subprocess.Popen(
        [BIN, "-c", "-l", "127.0.0.1:%d" % CP, "--path", "127.0.0.1:127.0.0.1:%d" % RP,
         "-k", KEY, "--log-level", "3"],
        stdout=open(os.path.join(tmp, "cli.log"), "w"), stderr=subprocess.STDOUT, env=env)
    procs = [relay, client]
    try:
        time.sleep(1.2)
        # drive uplink traffic through the WG side of the client; echo sink → downlink
        drv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        end = time.time() + 3.0
        while time.time() < end:
            drv.sendto(b"A" * 200, ("127.0.0.1", CP))
            try:
                while True:
                    data, who = sink.recvfrom(4096)
                    sink.sendto(data, who)          # echo → relay → client (downlink)
            except socket.timeout:
                pass
            time.sleep(0.02)
        time.sleep(2.0)   # let a report tick fire

        log = open(rlog).read()
        reports = re.findall(r"\[relay\]\[report\] period=.*", log)
        check("periodic [relay][report] info line appears", len(reports) >= 1,
              "count=%d" % len(reports))

        up_ok = dn_ok = False
        for r in reports:
            mu = re.search(r"up=\S+/(\d+)", r); md = re.search(r"down=\S+/(\d+)", r)
            if mu and int(mu.group(1)) > 0: up_ok = True
            if md and int(md.group(1)) > 0: dn_ok = True
        check("uplink bytes/pkts counted (up=.../N, N>0)", up_ok)
        check("downlink bytes/pkts counted (down=.../N, N>0)", dn_ok)
        check("report has live= and uniq=", all(k in reports[-1] for k in ("live=", "uniq=")) if reports else False)

        # fingerprint in per-session debug line matches the tool for 127.0.0.1
        fp_tool = subprocess.check_output(
            [BIN, "--fingerprint-ip", "127.0.0.1"], env=env).decode().split()[0]
        sess_fps = set(re.findall(r"\[relay\]\[report\] sess (cf:[0-9a-f]+)", log))
        check("per-session debug line uses fingerprint", len(sess_fps) >= 1,
              "fps=%s" % sorted(sess_fps))
        check("session fingerprint matches --fingerprint-ip 127.0.0.1",
              fp_tool in sess_fps, "tool=%s log=%s" % (fp_tool, sorted(sess_fps)))

        # new session line carries cf:, never a raw dotted-quad
        newlines = re.findall(r"new session: client=(\S+)", log)
        check("'new session' uses fingerprint, not raw IP",
              len(newlines) >= 1 and all(c.startswith("cf:") for c in newlines),
              "clients=%s" % newlines[:3])

        # ── flood safety at the DEFAULT log level (4): a fresh relay, garbage
        # burst must NOT flood the log (per-event logs are debug) and must be
        # counted as probe=N. (At -log-level 5, debug per-probe lines show by
        # design, so flood-safety is asserted at the operational default.) ──
        RP2 = free_port()
        flog = os.path.join(tmp, "relay4.log")
        relay4 = subprocess.Popen(
            [BIN, "-r", "-l", "127.0.0.1:%d" % RP2, "-k", KEY,
             "--upstream", "127.0.0.1:%d" % SINK, "--report", "1", "--log-level", "4"],
            stdout=open(flog, "w"), stderr=subprocess.STDOUT, env=env)
        procs.append(relay4)
        time.sleep(1.2)
        lines_before = len(open(flog).read().splitlines())
        for i in range(600):
            g = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            g.bind(("127.0.0.1", 0))
            g.sendto(b"\x40" + os.urandom(40), ("127.0.0.1", RP2))  # 0x40 = QUIC-ish, bad token
            g.close()
        time.sleep(2.5)
        log2 = open(flog).read()
        grew = len(log2.splitlines()) - lines_before
        check("flood does not flood the log at level 4 (new lines bounded)", grew < 40,
              "new_lines=%d for 600 garbage pkts" % grew)
        probes = [int(m) for m in re.findall(r"probe=(\d+)", log2)]
        check("probes counted in report (probe=N accumulates)",
              sum(probes) >= 300, "probe totals=%s" % probes[-3:])

    finally:
        for p in procs:
            p.send_signal(signal.SIGTERM)
        for p in procs:
            try: p.wait(timeout=3)
            except Exception: p.kill()

    print("결과: %d/%d 통과 %s" % (passed, passed + failed, "✓" if failed == 0 else "✗"))
    sys.exit(1 if failed else 0)

if __name__ == "__main__":
    main()
