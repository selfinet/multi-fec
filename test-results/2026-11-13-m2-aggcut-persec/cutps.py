#!/usr/bin/env python3
"""cutps.py — aggregate path0 cut at 6 Mbps with per-second (0.5 s tc) records, mini test network (2026-11-13).
Copied from 2026-11-12-m2-agg-ratelimit/aggtest.py; new phase cutps (CUT_MODES × CUT_REPS), flow() records remote rx start epochs.
(orig) duplicate vs aggregate under a per-path rate limit (10 Mbit/s each way) on the mini test network (2026-11-12).
Copied from 2026-11-12-m2-v143b/m2test.py; new phases shape_on / shapecheck / dupagg / aggcut, cleanup also removes shaping + mode drop-ins.

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
PHASES = sys.argv[2:] or ['setup', 'shape_on', 'cutps', 'cleanup']
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
    ssh(S, f'mkdir -p /root/mft; pkill -x mfgen; date +%s.%N > /root/mft/up.start; setsid nohup mfgen rx 10.9.30.1 {port_up} {secs + 4} > /root/mft/up.log 2>&1 < /dev/null &')
    ssh(C, f'mkdir -p /root/mft; pkill -x mfgen; date +%s.%N > /root/mft/dn.start; setsid nohup mfgen rx 10.9.30.2 {port_dn} {secs + 4} > /root/mft/dn.log 2>&1 < /dev/null &')
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
           'rm -rf /etc/systemd/system/multi-fec@client.service.d/m2test-version.conf /etc/systemd/system/multi-fec@client.service.d/m2test-zfailover.conf /etc/systemd/system/multi-fec@client.service.d/m2test-zagg.conf; tc qdisc del dev enp3s0 root 2>/dev/null; rm -f /usr/sbin/multi-fec-dist.client; systemctl daemon-reload')
    ssh(S, 'pkill -x mfgen; rm -f /etc/systemd/system/multi-fec@server.service.d/m2test-version.conf /etc/systemd/system/multi-fec@relay.service.d/m2test-version.conf '
           '/etc/systemd/system/multi-fec@server.service.d/m2test-zagg.conf /usr/sbin/multi-fec-dist.server /usr/sbin/multi-fec-dist.relay; tc qdisc del dev enp3s0 root 2>/dev/null; tc qdisc del dev enp4s0 root 2>/dev/null; systemctl daemon-reload; systemctl restart multi-fec@server; sleep 1; systemctl restart multi-fec@relay')
    ssh(C, 'systemctl restart multi-fec@client')
    for h in (C, S): ssh(h, 'touch /root/mft/tcs.stop')
    guard_stop(); time.sleep(8)
    log('cleanup: drop-ins removed, default binary', ssh(S, '/usr/sbin/multi-fec-dist --version | head -1').strip(),
        'units', ssh(S, 'systemctl is-active multi-fec@server multi-fec@relay').split(), ssh(C, 'systemctl is-active multi-fec@client').split(),
        'ping', ssh(C, 'ping -c 5 -i 0.2 -q 10.9.30.1 | tail -1').strip())
    for h in (C, S):
        log('cleanup qdisc', h, ssh(h, 'for i in enp3s0 enp4s0; do echo "$i $(tc qdisc show dev $i | head -1 | cut -c1-40)"; done; '
                                    'ls /etc/systemd/system/multi-fec@*.service.d/ 2>/dev/null | grep -c m2test; sha256sum /usr/sbin/multi-fec-dist | cut -c1-8').replace('\n', ' | '))


# ---------------- aggregate vs duplicate under a per-path rate limit ----------------
RATE = os.environ.get('RATE', '10mbit')
# (host, iface, u32 match) — only the multi-fec UDP of each path, everything else (ssh, mgmt) → unlimited default class
SHAPE = ((C, 'enp3s0', 'match ip dst 192.168.2.91/32 match ip dport 443 0xffff', 'p0_up'),
         (C, 'enp4s0', 'match ip dst 172.30.4.1/32 match ip dport 8443 0xffff', 'p1_up'),
         (S, 'enp3s0', 'match ip dst 192.168.2.90/32 match ip sport 443 0xffff', 'p0_dn'),
         (S, 'enp4s0', 'match ip dst 172.30.4.2/32 match ip sport 8443 0xffff', 'p1_dn'))
def phase_shape_on():
    for h, i, m, _ in SHAPE:
        ssh(h, f'tc qdisc replace dev {i} root handle 1: htb default 99 && '
               f'tc class add dev {i} parent 1: classid 1:99 htb rate 1gbit && '
               f'tc class add dev {i} parent 1: classid 1:10 htb rate {RATE} ceil {RATE} burst 15k && '
               f'tc qdisc add dev {i} parent 1:10 handle 10: pfifo limit 100 && '
               f'tc filter add dev {i} parent 1: protocol ip prio 1 u32 match ip protocol 17 0xff {m} flowid 1:10', check=True)
    log('shape_on', RATE, [ssh(h, f'tc class show dev {i} | grep -c htb').strip() for h, i, _, _ in SHAPE])
def shape_ctr():
    r = {}
    for h, i, _, name in SHAPE:
        out = ssh(h, f'tc -s class show dev {i} classid 1:10')
        m = re.search(r'Sent (\d+) bytes (\d+) pkt \(dropped (\d+), overlimits (\d+)', out)
        r[name] = (int(m[1]), int(m[2]), int(m[3])) if m else None
    return r
def shape_delta(a, b, secs):
    return {k: dict(mbps=round((b[k][0] - a[k][0]) * 8 / secs / 1e6, 2), drops=b[k][2] - a[k][2]) for k in a if a[k] and b[k]}

AGG_DROPIN = ('# aggtest 2026-11-12: multipath-mode override. Remove to restore.\n[Service]\nExecStart=\n'
              'ExecStart=/usr/sbin/multi-fec-dist.%i --config /etc/multi-fec/instances/%i.conf --multipath-mode aggregate\n')
def set_mode(mode):
    for h, i in ((C, 'client'), (S, 'server')):
        if mode == 'aggregate':
            subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', f'ControlPath={CP}/%h', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=20m',
                            '-J', 'stevekim@10.0.3.3', f'root@{h}', f'cat > /etc/systemd/system/multi-fec@{i}.service.d/m2test-zagg.conf'],
                           input=AGG_DROPIN, text=True, timeout=60, check=True)
        else:
            ssh(h, f'rm -f /etc/systemd/system/multi-fec@{i}.service.d/m2test-zagg.conf')
        ssh(h, 'systemctl daemon-reload')
def mode_seen():
    c = ssh(C, 'tr "\\0" " " < /proc/$(systemctl show -p MainPID --value multi-fec@client)/cmdline')
    s = ssh(S, 'tr "\\0" " " < /proc/$(systemctl show -p MainPID --value multi-fec@server)/cmdline')
    return dict(client_agg='aggregate' in c, server_agg='aggregate' in s)
def extra(secs):
    """EAGAIN counter range / pending lines in the last window, both ends"""
    q = f'--since "-{secs}s"'
    def nums(h, u):
        out = ssh(h, f'journalctl -u multi-fec@{u} --no-pager -o cat {q} | grep -oE "EAGAIN #[0-9]+" | grep -oE "[0-9]+$"').split()
        return [int(x) for x in out]
    cn, sn = nums(C, 'client'), nums(S, 'server')
    cp = ssh(C, f'journalctl -u multi-fec@client --no-pager -o cat {q} | grep -ciE "pending queue full"').strip()
    sp = ssh(S, f'journalctl -u multi-fec@server --no-pager -o cat {q} | grep -ciE "pending|EAGAIN"').strip()
    return dict(client_eagain_nums=(min(cn), max(cn)) if cn else None, server_eagain_nums=(min(sn), max(sn)) if sn else None,
                client_pending_full_lines=int(cp or 0), server_pending_or_eagain_lines=int(sp or 0))
def step(secs, mbps, **kw):
    a = shape_ctr(); r, ups, dns, t0 = flow(secs, mbps, during=kw.pop('during', None)); b = shape_ctr()
    r['shape'] = shape_delta(a, b, secs); r.update(extra(secs + 15))
    return r, ups, dns
def trips(r): return (r['cpu_client'] or {}).get('trips', 0) + (r['cpu_server'] or {}).get('trips', 0)

def phase_shapecheck():
    got = set_versions(NEW, NEW, NEW); set_mode('aggregate'); got = set_versions(NEW, NEW, NEW)
    r, _, _ = step(20, 4)
    result(phase='shapecheck', running=got, mode=mode_seen(), **r)

STEPS = [int(x) for x in os.environ.get('STEPS', '4,6,8,10,12,14,16').split(',')]
def phase_dupagg():
    for v, mode in ((NEW, 'duplicate'), (NEW, 'aggregate'), (OLD, 'aggregate')):
        set_mode(mode); got = set_versions(v, v, v); ms = mode_seen()
        for mbps in STEPS:
            r, _, _ = step(60, mbps)
            result(phase='dupagg', version=v, mode=mode, mode_seen=ms, running=got, mbps_each_way=mbps, **r)
            if trips(r): log('guard tripped', v, mode, mbps, '— next'); break

def phase_aggcut():
    set_mode('aggregate'); got = set_versions(NEW, NEW, NEW)
    for rep in range(3):
        ev = []
        def during(t0):
            while time.time() - t0 < 20: time.sleep(0.2)
            ssh(C, 'iptables -I OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -j DROP -m comment --comment m2test', check=True); ev.append(round(time.time() - t0, 1))
            while time.time() - t0 < 40: time.sleep(0.2)
            ssh(C, 'iptables -D OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -j DROP -m comment --comment m2test', check=True); ev.append(round(time.time() - t0, 1))
        try:
            r, ups, dns = step(60, 10, during=during)
        finally:
            ssh(C, 'iptables -S OUTPUT | grep m2test | sed s/^-A/-D/ | while read -r r; do eval iptables $r; done')
        exp = 10e6 / 8 / 1200
        def win(series, a, b):
            xs = [rx for s, rx in series if a <= s < b]
            return round(100 * (1 - sum(xs) / (exp * max(1, len(xs)))), 3) if xs else None
        wins = {w: dict(up=win(ups, a, b), down=win(dns, a, b)) for w, a, b in (('before', 2, 20), ('cut', 20, 40), ('after', 40, 58))}
        result(phase='aggcut', rep=rep, version=NEW, running=got, mode=mode_seen(), cut_at=ev, windows=wins, **r)

# ---------------- 2026-11-13: per-second path cut (aggregate vs duplicate) ----------------
TCS = r"""rm -f /root/mft/tcs.stop /root/mft/tcs.log
while [ ! -e /root/mft/tcs.stop ]; do
  l="$(date +%s.%N)"
  for i in enp3s0 enp4s0; do
    s=$(tc -s class show dev $i classid 1:10 | grep -oE 'Sent [0-9]+ bytes [0-9]+ pkt \(dropped [0-9]+' | tr -dc '0-9 ' | tr -s ' ')
    l="$l |$i $s"
  done
  echo "$l" >> /root/mft/tcs.log; sleep 0.5
done"""
def tcs_start():
    for h in (C, S):
        subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', f'ControlPath={CP}/%h', '-o', 'ControlMaster=auto', '-o', 'ControlPersist=20m',
                        '-J', 'stevekim@10.0.3.3', f'root@{h}', 'mkdir -p /root/mft; cat > /root/mft/tcs.sh'], input=TCS, text=True, timeout=60, check=True)
        ssh(h, 'rm -f /root/mft/tcs.stop; setsid nohup sh /root/mft/tcs.sh >/dev/null 2>&1 < /dev/null &')
def tcs_stop():
    for h in (C, S): ssh(h, 'touch /root/mft/tcs.stop')
    time.sleep(1.5)
    return {('client' if h == C else 'server'): ssh(h, 'cat /root/mft/tcs.log') for h in (C, S)}

CUT_MBPS = int(os.environ.get('CUT_MBPS', '6')); CUT_SECS = int(os.environ.get('CUT_SECS', '90'))
CUT_MODES = os.environ.get('CUT_MODES', 'aggregate:3,duplicate:1')
def phase_cutps():
    for spec in CUT_MODES.split(','):
        mode, reps = spec.split(':')
        set_mode(mode); got = set_versions(NEW, NEW, NEW); ms = mode_seen()
        for rep in range(int(reps)):
            ev = {}
            def during(t0):
                while time.time() - t0 < 20: time.sleep(0.2)
                ev['cut'] = float(ssh(C, 'iptables -I OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -j DROP -m comment --comment m2test && date +%s.%N', check=True))
                while time.time() - t0 < 40: time.sleep(0.2)
                ev['restore'] = float(ssh(C, 'iptables -D OUTPUT -o enp3s0 -p udp -d 192.168.2.91 --dport 443 -j DROP -m comment --comment m2test && date +%s.%N', check=True))
            tcs_start(); time.sleep(1)
            try:
                r, ups, dns = step(CUT_SECS, CUT_MBPS, during=during)
            finally:
                ssh(C, 'iptables -S OUTPUT | grep m2test | sed s/^-A/-D/ | while read -r r; do eval iptables $r; done')
                tcl = tcs_stop()
            raw = dict(mode=mode, rep=rep, mbps=CUT_MBPS, ev=ev,
                       up_start=float(ssh(S, 'cat /root/mft/up.start')), dn_start=float(ssh(C, 'cat /root/mft/dn.start')),
                       up_log=ssh(S, 'cat /root/mft/up.log'), dn_log=ssh(C, 'cat /root/mft/dn.log'), tcs=tcl,
                       client_journal=ssh(C, f'journalctl -u multi-fec@client --no-pager -o short-unix --since "-{CUT_SECS + 25}s" | sed "s/\\x1b\\[[0-9;]*m//g"'),
                       server_journal=ssh(S, f'journalctl -u multi-fec@server --no-pager -o short-unix --since "-{CUT_SECS + 25}s" | sed "s/\\x1b\\[[0-9;]*m//g"'))
            json.dump(raw, open(os.path.join(OUT, f'raw_{mode}_{rep}.json'), 'w'))
            result(phase='cutps', mode=mode, mode_seen=ms, rep=rep, version=NEW, running=got, ev=ev, **r)
            if trips(r): log('guard tripped', mode, rep)


log('== m2test start', PHASES)
if any(p in PHASES for p in ('mix', 'fault', 'ladder', 'smoke', 'shapecheck', 'dupagg', 'aggcut', 'cutps')): guard_start()
try:
    for p in PHASES: log('== phase', p); globals()['phase_' + p]()
finally:
    if 'cleanup' not in PHASES: guard_stop()
log('== m2test end')
