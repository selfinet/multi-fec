#!/usr/bin/env python3
"""caketest.py — CAKE (wg-quick PostUp) per-host fairness on the mini test network (2026-11-13).

Question: one PC behind WireGuard saturates the tunnel → does another PC still get low latency / a fair share
when CAKE sits on the wg interface (client egress dual-srchost = upload, server egress dual-dsthost = download)?

Bottleneck: HTB 10 Mbit on the multi-fec UDP of each path (copied from 2026-11-12 aggtest.py, pfifo 100), duplicate mode.
"PCs" = two extra addresses inside the tunnel on client-test: A 10.9.31.11 (iperf3 -P 8), B 10.9.31.12 (ping 0.2 s + iperf3 -P 1).
Server peer AllowedIPs += 10.9.31.0/24 at runtime (gone after wg-quick restart).

usage: caketest.py OUTDIR [phase ...]   phases: setup calib postup runs cleanup (default: all)
"""
import os, re, subprocess, sys, time, json, statistics

OUT = os.path.abspath(sys.argv[1]); os.makedirs(OUT, exist_ok=True)
PHASES = sys.argv[2:] or ['setup', 'calib', 'postup', 'runs', 'cleanup']
C, S = '192.168.2.90', '192.168.2.91'
CP = '/tmp/claude-1000/m2ssh'; os.makedirs(CP, exist_ok=True)
LOG = open(os.path.join(OUT, 'run.log'), 'a')
RES = open(os.path.join(OUT, 'results.jsonl'), 'a')
BAK = '/etc/wireguard/wg-test.conf.bak-2026-11-13'
A, B = '10.9.31.11', '10.9.31.12'
SECS = int(os.environ.get('SECS', '60'))
REPS = int(os.environ.get('REPS', '2'))
STATE = os.path.join(OUT, 'state.json')

def log(*a):
    s = time.strftime('%H:%M:%S ') + ' '.join(str(x) for x in a); print(s, flush=True); LOG.write(s + '\n'); LOG.flush()
def ssh(host, cmd, t=180, check=False):
    r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ControlMaster=auto', '-o', f'ControlPath={CP}/%h',
                        '-o', 'ControlPersist=20m', '-J', 'stevekim@10.0.3.3', f'root@{host}', cmd],
                       capture_output=True, text=True, timeout=t)
    if check and r.returncode: raise RuntimeError(f'{host}: {cmd[:100]} → {r.returncode} {r.stderr[-300:]}')
    return r.stdout
def result(**kw):
    kw['t'] = time.time(); RES.write(json.dumps(kw) + '\n'); RES.flush(); log('RESULT', json.dumps(kw))
def state(**kw):
    d = json.load(open(STATE)) if os.path.exists(STATE) else {}
    d.update(kw); json.dump(d, open(STATE, 'w')); return d

# ---------------- guard (kills the load on trip) ----------------
GUARD = r'''
import os, sys, time, subprocess
lim_tot, lim_core = float(sys.argv[1]), float(sys.argv[2])
def stat():
    d = {}
    for l in open('/proc/stat'):
        if l.startswith('cpu'):
            p = l.split(); v = list(map(int, p[1:8])); d[p[0]] = (sum(v), v[3] + v[4])
    return d
def net():
    r = {}
    for i in ('enp3s0', 'enp4s0'):
        b = '/sys/class/net/%s/statistics/' % i
        r[i] = int(open(b + 'rx_bytes').read()) + int(open(b + 'tx_bytes').read())
    return r
f = open('/root/mft/guard.log', 'a'); a, n = stat(), net(); bad = 0
while not os.path.exists('/root/mft/guard.stop'):
    time.sleep(1); b, m = stat(), net()
    pct = {k: 100.0 * (1 - (b[k][1] - a[k][1]) / max(1, b[k][0] - a[k][0])) for k in b}
    tot = pct['cpu']; core = max(v for k, v in pct.items() if k != 'cpu')
    m3 = (m['enp3s0'] - n['enp3s0']) * 8 / 1e6; m4 = (m['enp4s0'] - n['enp4s0']) * 8 / 1e6
    over = tot > lim_tot or core > lim_core or m3 > 170 or m4 > 1500
    bad = bad + 1 if over else 0
    f.write('%.0f %.1f %.1f %.1f %.1f%s\n' % (time.time(), tot, core, m3, m4, ' TRIP' if bad >= 3 else '')); f.flush()
    if bad >= 3:
        subprocess.run(['pkill', '-x', 'iperf3']); subprocess.run(['pkill', '-f', '^ping -D -n -I 10.9.31']); bad = 0
    a, n = b, m
'''
def guard_start():
    for h, lt, lc in ((C, 85, 95), (S, 88, 95)):
        subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', f'ControlPath={CP}/%h', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=20m',
                        '-J', 'stevekim@10.0.3.3', f'root@{h}', 'mkdir -p /root/mft; rm -f /root/mft/guard.stop; cat > /root/mft/guard.py'],
                       input=GUARD, text=True, capture_output=True, timeout=60, check=True)
        ssh(h, f'pgrep -f "^python3 /root/mft/guard.py" >/dev/null || {{ setsid nohup python3 /root/mft/guard.py {lt} {lc} >/dev/null 2>&1 < /dev/null & }}')
    time.sleep(2)
    n = [ssh(h, 'pgrep -fc "^python3 /root/mft/guard.py"').strip() for h in (C, S)]
    log('guard', n)
    if n != ['1', '1']: raise RuntimeError('guard not running on both hosts — not starting load (rule 0)')
def guard_alive():
    return [ssh(h, 'pgrep -fc "^python3 /root/mft/guard.py"').strip() for h in (C, S)] == ['1', '1']
def guard_trips(t0, t1):
    n = 0
    for h in (C, S):
        for l in ssh(h, 'cat /root/mft/guard.log').splitlines():
            p = l.split()
            if p and t0 <= float(p[0]) <= t1 and 'TRIP' in l: n += 1
    return n
def guard_max(h, t0, t1):
    rows = [l.split() for l in ssh(h, 'cat /root/mft/guard.log').splitlines() if l.strip()]
    w = [r for r in rows if t0 <= float(r[0]) <= t1]
    return dict(cpu=max((float(r[1]) for r in w), default=0), core=max((float(r[2]) for r in w), default=0))

# ---------------- bottleneck: HTB 10 Mbit on each path's multi-fec UDP ----------------
RATE = os.environ.get('RATE', '10mbit')
SHAPE = ((C, 'enp3s0', 'match ip dst 192.168.2.91/32 match ip dport 443 0xffff'),
         (C, 'enp4s0', 'match ip dst 172.30.4.1/32 match ip dport 8443 0xffff'),
         (S, 'enp3s0', 'match ip dst 192.168.2.90/32 match ip sport 443 0xffff'),
         (S, 'enp4s0', 'match ip dst 172.30.4.2/32 match ip sport 8443 0xffff'))

def pcs_on():
    """Two 'PCs' inside the tunnel. Runtime only — a wg-quick restart removes all of it."""
    pub = ssh(C, 'wg show wg-test public-key', check=True).strip()
    ssh(C, f'ip addr replace {A}/32 dev wg-test && ip addr replace {B}/32 dev wg-test', check=True)
    ssh(S, f'wg set wg-test peer {pub} allowed-ips 10.9.30.2/32,10.9.31.0/24 && ip route replace 10.9.31.0/24 dev wg-test', check=True)
    for src in (A, B):
        out = ssh(C, f'ping -c 3 -W 2 -I {src} 10.9.30.1 | tail -2')
        if ' 0% packet loss' not in out: raise RuntimeError(f'PC {src} cannot reach 10.9.30.1: {out}')
    log('pcs_on ok', A, B)

def phase_setup():
    # nothing of ours may be running; refuse to start on top of leftovers
    for h in (C, S):
        left = ssh(h, 'pgrep -a "iperf3|mfgen" ; tc qdisc show dev enp3s0 | grep -c htb').strip().splitlines()
        if left[:-1] or left[-1] != '0': raise RuntimeError(f'{h}: leftovers {left}')
    for h in (C, S):
        ssh(h, f'test -e {BAK} || cp -p /etc/wireguard/wg-test.conf {BAK}', check=True)
    for h, i, m in SHAPE:
        ssh(h, f'tc qdisc replace dev {i} root handle 1: htb default 99 && '
               f'tc class add dev {i} parent 1: classid 1:99 htb rate 1gbit && '
               f'tc class add dev {i} parent 1: classid 1:10 htb rate {RATE} ceil {RATE} burst 15k && '
               f'tc qdisc add dev {i} parent 1:10 handle 10: pfifo limit 100 && '
               f'tc filter add dev {i} parent 1: protocol ip prio 1 u32 match ip protocol 17 0xff {m} flowid 1:10', check=True)
    log('htb on', RATE)
    guard_start()
    ssh(S, 'pkill -x iperf3; for p in 5201 5202; do iperf3 -s -B 10.9.30.1 -p $p -D; done', check=True)
    time.sleep(1)
    log('iperf3 servers', ssh(S, 'pgrep -c -x iperf3').strip())
    pcs_on()

def cake_set(on, rate=None):
    if on:
        ssh(C, f'tc qdisc replace dev wg-test root cake bandwidth {rate} dual-srchost besteffort', check=True)
        ssh(S, f'tc qdisc replace dev wg-test root cake bandwidth {rate} dual-dsthost besteffort', check=True)
    else:
        for h in (C, S): ssh(h, 'tc qdisc del dev wg-test root 2>/dev/null; true')
    log('cake', on, rate, [ssh(h, 'tc qdisc show dev wg-test').strip() for h in (C, S)])

def iperf_bps(js, rev):
    try:
        d = json.loads(js); e = d['end']
        return round(e['sum_received']['bits_per_second'] / 1e6, 3)
    except Exception as ex:
        return None

def load(direction, with_b=True, tag=''):
    """A: iperf3 -P 8 from 10.9.31.11; B: ping 0.2 s + iperf3 -P 1 from 10.9.31.12. Returns metrics."""
    if not guard_alive(): raise RuntimeError('guard gone — stopping (rule 0)')
    R = '-R' if direction == 'dn' else ''
    ssh(C, 'mkdir -p /root/mft; rm -f /root/mft/a.json /root/mft/b.json /root/mft/ping.txt')
    t0 = time.time()
    ssh(C, f'setsid nohup iperf3 -c 10.9.30.1 -p 5201 -B {A} -P 8 -t {SECS} {R} -J > /root/mft/a.json 2>&1 < /dev/null &')
    if with_b:
        time.sleep(3)
        ssh(C, f'setsid nohup ping -D -n -I {B} -i 0.2 -w {SECS - 6} 10.9.30.1 > /root/mft/ping.txt 2>&1 < /dev/null &')
        ssh(C, f'setsid nohup iperf3 -c 10.9.30.1 -p 5202 -B {B} -P 1 -t {SECS - 6} {R} -J > /root/mft/b.json 2>&1 < /dev/null &')
    time.sleep(SECS + 4)
    for _ in range(20):
        if not ssh(C, 'pgrep -x iperf3; pgrep -f "^ping -D -n -I"').strip(): break
        time.sleep(1)
    t1 = time.time()
    a = iperf_bps(ssh(C, 'cat /root/mft/a.json'), R)
    m = dict(dir=direction, tag=tag, a_mbps=a, trips=guard_trips(t0, t1), cpu_c=guard_max(C, t0, t1), cpu_s=guard_max(S, t0, t1))
    if with_b:
        m['b_mbps'] = iperf_bps(ssh(C, 'cat /root/mft/b.json'), R)
        rtts = [float(x) for x in re.findall(r'time=([\d.]+) ms', ssh(C, 'cat /root/mft/ping.txt'))]
        sent = len(re.findall(r'icmp_seq=', ssh(C, 'cat /root/mft/ping.txt')))
        txl = re.search(r'(\d+) packets transmitted, (\d+) received', ssh(C, 'cat /root/mft/ping.txt'))
        if rtts:
            q = statistics.quantiles(rtts, n=100)
            m.update(ping_n=len(rtts), ping_p50=round(statistics.median(rtts), 1), ping_p90=round(q[89], 1),
                     ping_p99=round(q[98], 1), ping_max=round(max(rtts), 1))
        if txl: m['ping_loss_pct'] = round(100 * (1 - int(txl[2]) / max(1, int(txl[1]))), 2)
        if m.get('a_mbps') and m.get('b_mbps'): m['b_share'] = round(m['b_mbps'] / (m['a_mbps'] + m['b_mbps']), 3)
    m['eagain_c'] = int(ssh(C, f'journalctl -u multi-fec@client --no-pager -o cat --since "-{int(t1 - t0 + 5)}s" | grep -c "EAGAIN"').strip() or 0)
    m['cake_c'] = ssh(C, 'tc -s qdisc show dev wg-test | grep -E "Sent|drops|bulk_flows" | head -3').strip()
    m['cake_s'] = ssh(S, 'tc -s qdisc show dev wg-test | grep -E "Sent|drops|bulk_flows" | head -3').strip()
    return m

def idle_ping():
    out = ssh(C, f'ping -n -I {B} -i 0.2 -c 50 10.9.30.1 | tail -1')
    return out.strip()

def phase_calib():
    cake_set(False)
    log('idle ping (no load)', idle_ping())
    r = {}
    for d in ('up', 'dn'):
        m = load(d, with_b=False, tag='calib'); result(kind='calib', **m); r[d] = m['a_mbps']
        time.sleep(5)
    g = min(v for v in r.values() if v)
    rate = os.environ.get('CAKE_RATE') or f'{int(g * 0.85 * 1000)}kbit'
    state(calib=r, cake_rate=rate)
    log('calib goodput', r, '→ CAKE rate', rate)

def wait_tunnel(limit=90):
    """Seconds until the tunnel answers again after a wg-quick restart (None = never within limit)."""
    t0 = time.time()
    while time.time() - t0 < limit:
        if ' 0% packet loss' in ssh(C, 'ping -c 1 -W 1 10.9.30.1 | tail -2'): return round(time.time() - t0, 1)
        time.sleep(0.5)
    return None

def phase_postup():
    rate = state()['cake_rate']
    pc = f'PostUp = tc qdisc replace dev %i root cake bandwidth {rate} dual-srchost besteffort'
    ps = f'PostUp = tc qdisc replace dev %i root cake bandwidth {rate} dual-dsthost besteffort'
    for h, line in ((C, pc), (S, ps)):
        # restore the original first so a re-run never stacks two PostUp lines
        ssh(h, f'cp -p {BAK} /etc/wireguard/wg-test.conf && '
               f'sed -i "/^PostUp = wg set/a {line}" /etc/wireguard/wg-test.conf && grep -c "^PostUp = tc qdisc" /etc/wireguard/wg-test.conf', check=True)
    for h in (C, S): ssh(h, 'systemctl restart wg-quick@wg-test', check=True)
    back = wait_tunnel()
    q = [ssh(h, 'tc qdisc show dev wg-test').strip() for h in (C, S)]
    ok = all('cake' in x for x in q)
    result(kind='postup_check', after='restart 1', ok=ok, tunnel_back_s=back, qdisc=q)
    # second restart: PostUp must re-apply on a re-created interface
    for h in (C, S): ssh(h, 'systemctl restart wg-quick@wg-test', check=True)
    back = wait_tunnel()
    q = [ssh(h, 'tc qdisc show dev wg-test').strip() for h in (C, S)]
    result(kind='postup_check', after='restart 2', ok=all('cake' in x for x in q), tunnel_back_s=back, qdisc=q)
    if back is None: raise RuntimeError('tunnel did not come back within 90 s after wg-quick restart')
    out = ssh(C, 'ping -c 5 -W 2 10.9.30.1 | tail -2')
    log('wg after restart', out.strip())
    pcs_on()   # runtime PCs were removed by the restart

def phase_runs():
    rate = state()['cake_rate']
    log('idle ping, CAKE on', (cake_set(True, rate), idle_ping())[1])
    for rep in range(REPS):
        for d in ('up', 'dn'):
            for on in ((False, True) if rep % 2 == 0 else (True, False)):
                cake_set(on, rate)
                m = load(d, tag=f'rep{rep}')
                result(kind='run', cake=on, rate=rate if on else None, rep=rep, **m)
                time.sleep(5)
    cake_set(True, rate)   # leave as PostUp left it until cleanup

def phase_sweep():
    """CAKE rate as % of each direction's own calibrated goodput — where does the protection stop?"""
    cal = state()['calib']
    pcts = [int(x) for x in os.environ.get('SWEEP', '85,90,95,100,105').split(',')]
    for d in ('up', 'dn'):
        cake_set(False)
        m = load(d, tag='sweep_off'); result(kind='sweep', pct=None, rate=None, calib=cal[d], **m); time.sleep(5)
        for pct in pcts:
            rate = f'{int(cal[d] * pct * 10)}kbit'
            cake_set(True, rate)
            m = load(d, tag=f'sweep{pct}')
            result(kind='sweep', pct=pct, rate=rate, calib=cal[d], **m)
            time.sleep(5)
    cake_set(False)

def phase_cleanup():
    for h in (C, S): ssh(h, 'touch /root/mft/guard.stop; pkill -x iperf3; pkill -f "^ping -D -n -I"; true')
    for h in (C, S):
        ssh(h, f'test -e {BAK} && cp -p {BAK} /etc/wireguard/wg-test.conf && systemctl restart wg-quick@wg-test', check=True)
        for _, i, _ in [x for x in SHAPE if x[0] == h]:
            ssh(h, f'tc qdisc del dev {i} root 2>/dev/null; true')
    time.sleep(3)
    for h in (C, S):
        log('final', h, ssh(h, 'grep -c "^PostUp = tc" /etc/wireguard/wg-test.conf; tc qdisc show | grep -cE "htb|cake"; '
                               'ip -br addr show wg-test; pgrep -c -x iperf3; systemctl is-active wg-quick@wg-test').split())
    log('wg ping', ssh(C, 'ping -c 5 -W 2 10.9.30.1 | tail -2').strip())
    log('multi-fec', ssh(C, 'systemctl is-active multi-fec@client').strip(), ssh(S, 'systemctl is-active multi-fec@server multi-fec@relay').split())

try:
    for p in PHASES:
        log('== phase', p); globals()['phase_' + p]()
except Exception as e:
    log('ERROR', repr(e))
    if 'cleanup' in PHASES and PHASES[-1] == 'cleanup':
        log('== emergency cleanup'); phase_cleanup()
    sys.exit(1)
log('done')
