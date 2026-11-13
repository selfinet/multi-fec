#!/usr/bin/env python3
"""restart.py — why does the tunnel take ~16 s to come back after `systemctl restart wg-quick@wg-test`? (mini, 2026-11-13)

Cases: client only / server only / both (client then server, like caketest.py), REPS each. No load, no shaping.
Recorded on the hosts themselves (sub-second, no ssh latency):
  client: ping 10.9.30.1 every 0.2 s (timestamped successes), `wg show latest-handshakes` every 0.2 s
  both:   tcpdump on lo for the WG<->multi-fec legs (client udp 51821, server udp 51820) — sizes tell
          handshake initiation (148) / response (92) / cookie (64) / data apart
usage: restart.py OUTDIR
"""
import os, re, subprocess, sys, time, json

OUT = os.path.abspath(sys.argv[1]); os.makedirs(OUT, exist_ok=True)
C, S = '192.168.2.90', '192.168.2.91'
CP = '/tmp/claude-1000/m2ssh'
REPS = int(os.environ.get('REPS', '2')); WIN = 40
LOG = open(os.path.join(OUT, 'restart.log'), 'a'); RES = open(os.path.join(OUT, 'restart.jsonl'), 'a')
def log(*a):
    s = time.strftime('%H:%M:%S ') + ' '.join(str(x) for x in a); print(s, flush=True); LOG.write(s + '\n'); LOG.flush()
def ssh(host, cmd, t=120, check=False):
    r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ControlMaster=auto', '-o', f'ControlPath={CP}/%h',
                        '-o', 'ControlPersist=20m', '-J', 'stevekim@10.0.3.3', f'root@{host}', cmd], capture_output=True, text=True, timeout=t)
    if check and r.returncode: raise RuntimeError(f'{host}: {cmd[:100]} → {r.returncode} {r.stderr[-300:]}')
    return r.stdout

def start_rec(tag):
    ssh(C, f'mkdir -p /root/mft/rs; cd /root/mft/rs; rm -f {tag}.*; '
           f'setsid nohup timeout {WIN} tcpdump -i lo -nn -tt -l "udp port 51821" > {tag}.lo 2>/dev/null < /dev/null & '
           f'setsid nohup timeout {WIN} bash -c \'while :; do ping -c1 -W0.5 10.9.30.1 >/dev/null && date +%s.%N; sleep 0.2; done\' > {tag}.ping 2>/dev/null < /dev/null & '
           f'setsid nohup timeout {WIN} bash -c \'while :; do echo $(date +%s.%N) $(wg show wg-test latest-handshakes 2>/dev/null | awk "{{print \\$2}}"); sleep 0.2; done\' > {tag}.hs 2>/dev/null < /dev/null &', check=True)
    ssh(S, f'mkdir -p /root/mft/rs; cd /root/mft/rs; rm -f {tag}.*; '
           f'setsid nohup timeout {WIN} tcpdump -i lo -nn -tt -l "udp port 51820" > {tag}.lo 2>/dev/null < /dev/null & '
           f'setsid nohup timeout {WIN} bash -c \'while :; do echo $(date +%s.%N) $(wg show wg-test latest-handshakes 2>/dev/null | awk "{{print \\$2}}"); sleep 0.2; done\' > {tag}.hs 2>/dev/null < /dev/null &', check=True)
    time.sleep(3)

def lo_events(txt, t0, wgport):
    """(t, direction, len) for packets on lo; direction 'wg->mf' when the WG side is the source."""
    ev = []
    for l in txt.splitlines():
        m = re.match(r'([\d.]+) IP 127\.0\.0\.1\.(\d+) > 127\.0\.0\.1\.(\d+): UDP, length (\d+)', l)
        if not m: continue
        t, sp, dp, n = float(m[1]), int(m[2]), int(m[3]), int(m[4])
        d = 'wg->mf' if (wgport and sp == wgport) or (not wgport and dp in (51821,)) else 'mf->wg'
        ev.append((round(t - t0, 2), sp, dp, n))
    return ev

def one(case, rep):
    tag = f'{case}_{rep}'
    start_rec(tag)
    t0 = time.time()
    if case in ('client', 'both'): ssh(C, 'systemctl restart wg-quick@wg-test', check=True)
    tc = time.time()
    if case in ('server', 'both'): ssh(S, 'systemctl restart wg-quick@wg-test', check=True)
    ts = time.time()
    time.sleep(WIN - (time.time() - t0) + 1)
    pings = [float(x) for x in ssh(C, f'cat /root/mft/rs/{tag}.ping').split()]
    after = [p for p in pings if p > ts]
    back = round(after[0] - t0, 2) if after else None
    def hs(h):
        ch = []; prev = None
        for l in ssh(h, f'cat /root/mft/rs/{tag}.hs').splitlines():
            p = l.split()
            if len(p) == 2 and p[1] != prev:
                ch.append((round(float(p[0]) - t0, 2), int(p[1]))); prev = p[1]
        return [(t, (round(v - t0, 1) if v else 0)) for t, v in ch]
    clo = ssh(C, f'cat /root/mft/rs/{tag}.lo'); slo = ssh(S, f'cat /root/mft/rs/{tag}.lo')
    def evs(txt):
        out = []
        for l in txt.splitlines():
            m = re.match(r'([\d.]+) IP 127\.0\.0\.1\.(\d+) > 127\.0\.0\.1\.(\d+): UDP, length (\d+)', l)
            if m: out.append((round(float(m[1]) - t0, 2), int(m[2]), int(m[3]), int(m[4])))
        return out
    ce, se = evs(clo), evs(slo)
    small = lambda e: [x for x in e if x[3] in (148, 92, 64)]
    r = dict(case=case, rep=rep, restart_client_done=round(tc - t0, 2), restart_server_done=round(ts - t0, 2),
             ping_back_s=back, hs_client=hs(C), hs_server=hs(S),
             lo_client_handshake=small(ce)[:20], lo_server_handshake=small(se)[:20],
             lo_client_n=len(ce), lo_server_n=len(se),
             mf_client_log=ssh(C, f'journalctl -u multi-fec@client --since "@{int(t0) - 1}" --until "@{int(t0) + WIN}" --no-pager -o short-unix | tail -15'),
             mf_server_log=ssh(S, f'journalctl -u multi-fec@server --since "@{int(t0) - 1}" --until "@{int(t0) + WIN}" --no-pager -o short-unix | tail -15'))
    RES.write(json.dumps(r) + '\n'); RES.flush()
    log(case, rep, 'ping back', back, 's; client hs', r['hs_client'], 'server hs', r['hs_server'])
    log('  client lo hs-sized', r['lo_client_handshake'][:10])
    log('  server lo hs-sized', r['lo_server_handshake'][:10])

for rep in range(REPS):
    for case in ('client', 'server', 'both'):
        one(case, rep); time.sleep(5)
log('final ping', ssh(C, 'ping -c 3 -W 2 10.9.30.1 | tail -2').strip())
log('leftovers', ssh(C, 'pgrep -c tcpdump; pgrep -fc "while :"').split(), ssh(S, 'pgrep -c tcpdump').split())
