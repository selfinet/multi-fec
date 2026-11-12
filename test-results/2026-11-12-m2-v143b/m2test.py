#!/usr/bin/env python3
"""m2test.py — 1.4.1 / 1.4.3(tag 2563f2a) / 1.4.3b(86e6683, 3rd-round fix) on the mini test network (2026-11-12).
Copied from 2026-11-09-m2-v141-v143; versions come from env OLD/NEW/TAG, new phase `failover`.

Topology: client-test 192.168.2.90 → path[0] enp3s0 → test-server 192.168.2.91:443
                                    → path[1] enp4s0 → relay 172.30.4.1:8443 → 172.30.4.1:443
Traffic: mfgen inside WireGuard wg-test (client 10.9.30.2 ↔ server 10.9.30.1), both directions.
Phases: mix (8 server/relay/client version combos) · fault (per version) · ladder (per version).
A guard on each host (CPU / link) kills mfgen on trip. Version per instance via a systemd drop-in
that runs /usr/sbin/multi-fec-dist.<instance> (a symlink); removed by `cleanup`.

usage: m2test.py OUTDIR [phase ...]   phases: setup mix fault ladder cleanup (default: all)
"""
import os, re, subprocess, sys, time, json

OUT = os.path.abspath(sys.argv[1]); os.makedirs(OUT, exist_ok=True)
PHASES = sys.argv[2:] or ['setup', 'mix', 'fault', 'ladder', 'failover', 'cleanup']
OLD, NEW, TAG = os.environ.get('OLD', '1.4.1'), os.environ.get('NEW', '1.4.3b'), os.environ.get('TAG', '1.4.3')
C, S = '192.168.2.90', '192.168.2.91'
CP = '/tmp/claude-1000/m2ssh'; os.makedirs(CP, exist_ok=True)
LOG = open(os.path.join(OUT, 'run.log'), 'a')
RES = open(os.path.join(OUT, 'results.jsonl'), 'a')
def log(*a):
    s = time.strftime('%H:%M:%S ') + ' '.join(str(x) for x in a); print(s, flush=True); LOG.write(s + '\n'); LOG.flush()
def ssh(host, cmd, t=120, check=False):
    r = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ControlMaster=auto', '-o', f'ControlPath={CP}/%h',
                        '-o', 'ControlPersist=20m', '-J', 'stevekim@10.0.3.3', f'root@{host}', cmd],
                       capture_output=True, text=True, timeout=t)
    if check and r.returncode: raise RuntimeError(f'{host}: {cmd[:80]} → {r.returncode} {r.stderr[-300:]}')
    return r.stdout
def result(**kw):
    kw['t'] = time.time(); RES.write(json.dumps(kw) + '\n'); RES.flush(); log('RESULT', json.dumps(kw))

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
        subprocess.run(['pkill', '-x', 'mfgen']); bad = 0
    a, n = b, m
'''

def guard_start():
    for h, lt, lc in ((C, 85, 95), (S, 88, 95)):
        p = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', f'ControlPath={CP}/%h', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=20m',
                            '-J', 'stevekim@10.0.3.3', f'root@{h}', 'mkdir -p /root/mft; rm -f /root/mft/guard.stop; cat > /root/mft/guard.py'],
                           input=GUARD, text=True, capture_output=True, timeout=60)
        ssh(h, f'pgrep -f "^python3 /root/mft/guard.py" >/dev/null || {{ setsid nohup python3 /root/mft/guard.py {lt} {lc} >/dev/null 2>&1 < /dev/null & }}')
    time.sleep(2)
    log('guard', ssh(C, 'pgrep -fc "^python3 /root/mft/guard.py"').strip(), ssh(S, 'pgrep -fc "^python3 /root/mft/guard.py"').strip())
def guard_stop():
    for h in (C, S): ssh(h, 'touch /root/mft/guard.stop')
def guard_window(h, t0, t1):
    rows = [l.split() for l in ssh(h, 'cat /root/mft/guard.log').splitlines() if l.strip()]
    w = [r for r in rows if t0 <= float(r[0]) <= t1]
    if not w: return {}
    f = lambda i: round(sum(float(r[i]) for r in w) / len(w), 1)
    return dict(cpu=f(1), core_max=max(float(r[2]) for r in w), enp3s0=f(3), enp4s0=f(4), trips=sum('TRIP' in r for r in w))

def set_versions(sv, rv, cv):
    ssh(S, f'cd /usr/sbin && ln -sfn multi-fec-dist.v{sv} multi-fec-dist.server && ln -sfn multi-fec-dist.v{rv} multi-fec-dist.relay && '
           'systemctl restart multi-fec@server && sleep 1 && systemctl restart multi-fec@relay', check=True)
    ssh(C, f'cd /usr/sbin && ln -sfn multi-fec-dist.v{cv} multi-fec-dist.client && systemctl restart multi-fec@client', check=True)
    time.sleep(8)
    got = (ssh(S, 'for i in server relay; do /proc/$(systemctl show -p MainPID --value multi-fec@$i)/exe --version | head -1; done').split() +
           ssh(C, '/proc/$(systemctl show -p MainPID --value multi-fec@client)/exe --version | head -1').split())
    return ' '.join(x for x in got if re.match(r'\d+\.\d+\.\d+', x))

def flow(secs, mbps, port_up=5201, port_dn=5202, during=None, tag=''):
    """bidirectional mfgen through the tunnel; returns totals + per-second rx lines"""
    ssh(S, f'mkdir -p /root/mft; pkill -x mfgen; setsid nohup mfgen rx 10.9.30.1 {port_up} {secs + 4} > /root/mft/up.log 2>&1 < /dev/null &')
    ssh(C, f'mkdir -p /root/mft; pkill -x mfgen; setsid nohup mfgen rx 10.9.30.2 {port_dn} {secs + 4} > /root/mft/dn.log 2>&1 < /dev/null &')
    time.sleep(1); t0 = time.time()
    ssh(C, f'setsid nohup mfgen tx 10.9.30.1 {port_up} {mbps} {secs} 1200 > /root/mft/txu.log 2>&1 < /dev/null &')
    ssh(S, f'setsid nohup mfgen tx 10.9.30.2 {port_dn} {mbps} {secs} 1200 > /root/mft/txd.log 2>&1 < /dev/null &')
    if during: during(t0)
    while time.time() - t0 < secs + 6: time.sleep(1)
    t1 = time.time()
    def tot(h, f):
        out = ssh(h, f'cat /root/mft/{f}')
        m = re.search(r'total expected (\d+) rx (\d+) lost (-?\d+) loss_pct ([\d.]+) dup (\d+) ooo (\d+)', out)
        secs_ = [tuple(map(float, re.findall(r'sec (\d+) rx (\d+)', l)[0])) for l in out.splitlines() if l.startswith('sec ')]
        return (dict(exp=int(m[1]), rx=int(m[2]), loss_pct=float(m[4]), dup=int(m[5]), ooo=int(m[6])) if m else {'raw': out[-200:]}), secs_
    up, ups = tot(S, 'up.log'); dn, dns = tot(C, 'dn.log')
    paths = ssh(C, 'journalctl -u multi-fec@client --no-pager -o cat --since "-40s" | sed "s/\\x1b\\[[0-9;]*m//g" | '
                   'grep -E "path\\[[01]\\] [A-Z]+ " | tail -2 | sed -E "s/.*(path\\[[01]\\] [A-Z]+) owd=([0-9.]+)ms.*loss=([0-9]+%).*/\\1 owd=\\2 loss=\\3/"').split('\n')
    eag = ssh(C, 'journalctl -u multi-fec@client --no-pager -o cat --since "-%ds" | grep -c "mud_send EAGAIN"' % int(t1 - t0 + 5)).strip()
    return dict(up=up, down=dn, paths=[p for p in paths if p], client_eagain_lines=int(eag or 0),
                cpu_client=guard_window(C, t0, t1), cpu_server=guard_window(S, t0, t1)), ups, dns, t0

def phase_setup():
    dropin = ('[Service]\nExecStartPre=\nExecStartPre=/bin/mkdir -p /run/multi-fec\n'
              'ExecStartPre=/usr/sbin/multi-fec-dist.%i --config /etc/multi-fec/instances/%i.conf --apply-routes\n'
              'ExecStart=\nExecStart=/usr/sbin/multi-fec-dist.%i --config /etc/multi-fec/instances/%i.conf\n')
    for h, insts in ((S, ('server', 'relay')), (C, ('client',))):
        for i in insts:
            subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', f'ControlPath={CP}/%h', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=20m',
                            '-J', 'stevekim@10.0.3.3', f'root@{h}',
                            f'mkdir -p /etc/systemd/system/multi-fec@{i}.service.d && cat > /etc/systemd/system/multi-fec@{i}.service.d/m2test-version.conf'],
                           input='# m2test 2026-11-09: per-instance binary symlink /usr/sbin/multi-fec-dist.<instance>. Remove to restore.\n' + dropin,
                           text=True, timeout=60, check=True)
            ssh(h, f'ln -sfn multi-fec-dist.v{NEW} /usr/sbin/multi-fec-dist.{i}')
        ssh(h, 'systemctl daemon-reload')
    log('setup: drop-ins installed')

def phase_mix():
    for sv in (OLD, NEW):
        for rv in (OLD, NEW):
            for cv in (OLD, NEW):
                got = set_versions(sv, rv, cv)
                r, _, _, _ = flow(20, 5)
                result(phase='mix', server=sv, relay=rv, client=cv, running=got, **r)

def phase_fault():
    for v in (TAG, NEW):
        set_versions(v, v, v)
        ev = []
        def during(t0):
            def at(t, what, h, cmd):
                while time.time() - t0 < t: time.sleep(0.2)
                ssh(h, cmd, check=True); ev.append((round(time.time() - t0, 1), what)); log('event', what)
            at(20, 'cut path0 (iptables drop udp→.91:443 on enp3s0)', C, 'iptables -I OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -j DROP -m comment --comment m2test')
            at(40, 'restore path0', C, 'iptables -D OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -j DROP -m comment --comment m2test')
            at(55, 'stop relay (path1 down)', S, 'systemctl stop multi-fec@relay')
            at(75, 'start relay', S, 'systemctl start multi-fec@relay')
            at(90, 'netem enp4s0 loss 10% delay 20ms (client)', C, 'tc qdisc replace dev enp4s0 root netem delay 20ms 5ms loss 10%')
            at(110, 'netem off', C, 'tc qdisc del dev enp4s0 root')
            at(120, 'enp3s0 udp443 random loss 5% (client out)', C, 'iptables -I OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -m statistic --mode random --probability 0.05 -j DROP -m comment --comment m2test')
            at(140, 'loss off', C, 'iptables -D OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -m statistic --mode random --probability 0.05 -j DROP -m comment --comment m2test')
            at(150, 'both paths lossy: enp4s0 netem 10% + enp3s0 5%', C, 'tc qdisc replace dev enp4s0 root netem loss 10%; iptables -I OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -m statistic --mode random --probability 0.05 -j DROP -m comment --comment m2test')
            at(170, 'all impairment off', C, 'tc qdisc del dev enp4s0 root; iptables -D OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -m statistic --mode random --probability 0.05 -j DROP -m comment --comment m2test')
            at(185, 'restart server', S, 'systemctl restart multi-fec@server')
            at(205, 'restart client', C, 'systemctl restart multi-fec@client')
        r, ups, dns, t0 = flow(230, 5, during=during)
        # per-event-window loss from per-second rx counts (expected pps = 5e6/8/1200 ≈ 520.8)
        exp = 5e6 / 8 / 1200
        def win(series, a, b):
            xs = [rx for s, rx in series if a <= s < b]
            return round(100 * (1 - sum(xs) / (exp * max(1, len(xs)))), 3) if xs else None
        bounds = [(0, 20, 'baseline')] + [(round(ev[i][0]), round(ev[i + 1][0]) if i + 1 < len(ev) else 230, ev[i][1]) for i in range(len(ev))]
        wins = [dict(window=f'{a}-{b}s', what=w, up_loss=win(ups, a, b), down_loss=win(dns, a, b)) for a, b, w in bounds]
        outage = lambda series: sum(1 for s, rx in series if rx < exp * 0.5 and s < 228)
        result(phase='fault', version=v, events=ev, windows=wins, seconds_below_50pct=dict(up=outage(ups), down=outage(dns)), **r)
        ssh(C, 'tc qdisc del dev enp4s0 root 2>/dev/null; iptables -S OUTPUT | grep m2test | sed s/^-A/-D/ | while read -r r; do eval iptables $r; done; '
               'iptables -S OUTPUT | grep -c m2test')

def phase_ladder():
    for v in (NEW,):
        set_versions(v, v, v)
        for mbps in (5, 10, 20, 30, 40):
            r, _, _, _ = flow(25, mbps)
            result(phase='ladder', version=v, mbps_each_way=mbps, **r)
            trips = (r['cpu_client'] or {}).get('trips', 0) + (r['cpu_server'] or {}).get('trips', 0)
            if trips:
                log('guard tripped at', mbps, 'Mbps — stopping ladder for', v); break


FO_DROPIN = ('# m2test 2026-11-12: client failover override. Remove to restore.\n[Service]\nExecStart=\n'
             'ExecStart=/usr/sbin/multi-fec-dist.%i --config /etc/multi-fec/instances/%i.conf --multipath-mode failover\n')
def phase_failover():
    """client in failover (server stays duplicate), path0 enp3s0 2% loss + path1 enp4s0 10% loss, 60 s 5 Mbps, 3 runs/version.
    3rd-round fix: mud_select_path() with stale snapshot rate → EAGAIN + latency."""
    subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', f'ControlPath={CP}/%h', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=20m',
                    '-J', 'stevekim@10.0.3.3', f'root@{C}', 'cat > /etc/systemd/system/multi-fec@client.service.d/m2test-zfailover.conf && systemctl daemon-reload'],
                   input=FO_DROPIN, text=True, timeout=60, check=True)
    try:
        for rep in range(3):
            for v in (TAG, NEW):
                got = set_versions(v, v, v)
                mode = ssh(C, 'tr "\\0" " " < /proc/$(systemctl show -p MainPID --value multi-fec@client)/cmdline').strip()
                ssh(C, 'iptables -I OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -m statistic --mode random --probability 0.02 -j DROP -m comment --comment m2test; '
                       'tc qdisc replace dev enp4s0 root netem loss 10%', check=True)
                try:
                    r, ups, dns, t0 = flow(60, 5)
                finally:
                    ssh(C, 'tc qdisc del dev enp4s0 root 2>/dev/null; iptables -S OUTPUT | grep m2test | sed s/^-A/-D/ | while read -r r; do eval iptables $r; done')
                pend = ssh(C, 'journalctl -u multi-fec@client --no-pager -o cat --since "-75s" | grep -ciE "pending.*(full|drop)"').strip()
                result(phase='failover', rep=rep, version=v, running=got, cmd_has_failover='failover' in mode, client_pending_lines=int(pend or 0), **r)
    finally:
        ssh(C, 'rm -f /etc/systemd/system/multi-fec@client.service.d/m2test-zfailover.conf; systemctl daemon-reload')

def phase_smoke():
    got = set_versions(NEW, NEW, NEW)
    r, _, _, _ = flow(10, 5)
    result(phase='smoke', running=got, **r)

def phase_cleanup():
    ssh(C, 'tc qdisc del dev enp4s0 root 2>/dev/null; iptables -S OUTPUT | grep m2test | sed s/^-A/-D/ | while read -r r; do eval iptables $r; done; pkill -x mfgen; '
           'rm -rf /etc/systemd/system/multi-fec@client.service.d/m2test-version.conf /etc/systemd/system/multi-fec@client.service.d/m2test-zfailover.conf; rm -f /usr/sbin/multi-fec-dist.client; systemctl daemon-reload')
    ssh(S, 'pkill -x mfgen; rm -f /etc/systemd/system/multi-fec@server.service.d/m2test-version.conf /etc/systemd/system/multi-fec@relay.service.d/m2test-version.conf '
           '/usr/sbin/multi-fec-dist.server /usr/sbin/multi-fec-dist.relay; systemctl daemon-reload; systemctl restart multi-fec@server; sleep 1; systemctl restart multi-fec@relay')
    ssh(C, 'systemctl restart multi-fec@client')
    guard_stop(); time.sleep(8)
    log('cleanup: drop-ins removed, default binary', ssh(S, '/usr/sbin/multi-fec-dist --version | head -1').strip(),
        'units', ssh(S, 'systemctl is-active multi-fec@server multi-fec@relay').split(), ssh(C, 'systemctl is-active multi-fec@client').split(),
        'ping', ssh(C, 'ping -c 5 -i 0.2 -q 10.9.30.1 | tail -1').strip())

log('== m2test start', PHASES)
if any(p in PHASES for p in ('mix', 'fault', 'ladder', 'smoke')): guard_start()
try:
    for p in PHASES: log('== phase', p); globals()['phase_' + p]()
finally:
    if 'cleanup' not in PHASES: guard_stop()
log('== m2test end')
