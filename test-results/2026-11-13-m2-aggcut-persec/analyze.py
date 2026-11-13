#!/usr/bin/env python3
"""analyze.py — per-second view of raw_<mode>_<rep>.json from cutps.py (2026-11-13).
Time axis = seconds relative to the cut (remote client clock; client↔server chrony offset ~µs).
mfgen rx 'sec k' covers [start+k, start+k+1). tc samples (0.5 s) are binned to the same 1 s grid.
usage: analyze.py DIR"""
import json, glob, math, os, re, sys

D = sys.argv[1]
def rx_series(log, start):
    return {start + int(k): int(rx) for k, rx in re.findall(r'^sec (\d+) rx (\d+)', log, re.M)}
def tc_series(log):
    rows = []
    for l in log.splitlines():
        p = l.split('|')
        if len(p) < 3: continue
        t = float(p[0]); v = []
        for seg in p[1:]:
            n = seg.split()[1:]
            v.append((int(n[0]), int(n[2])) if len(n) >= 3 else None)
        rows.append((t, v))
    return rows
def tc_bins(rows, origin, lo, hi):
    """Mbit/s and drops per 1 s bin [origin+s, origin+s+1) for each iface, from counter deltas"""
    out = {}
    for (ta, va), (tb, vb) in zip(rows, rows[1:]):
        s = math.floor((ta + tb) / 2 - origin)
        if not (lo <= s < hi): continue
        for i in range(2):
            if va[i] is None or vb[i] is None: continue
            b = out.setdefault(s, [[0, 0, 0.0], [0, 0, 0.0]])[i]
            b[0] += vb[i][0] - va[i][0]; b[1] += vb[i][1] - va[i][1]; b[2] += tb - ta
    return {s: [(round(x[0] * 8 / x[2] / 1e6, 2) if x[2] else None, x[1]) for x in v] for s, v in out.items()}

summary = []
for f in sorted(glob.glob(os.path.join(D, 'raw_*.json'))):
    r = json.load(open(f)); cut, rst = r['ev']['cut'], r['ev']['restore']
    exp = r['mbps'] * 1e6 / 8 / 1200
    up = rx_series(r['up_log'], r['up_start']); dn = rx_series(r['dn_log'], r['dn_start'])
    def at(series, s):
        """rx in the 1 s bin starting at cut+s, interpolated from mfgen's own grid"""
        t = cut + s; ks = sorted(series)
        tot = 0.0
        for k in ks:
            a, b = max(k, t), min(k + 1, t + 1)
            if b > a: tot += series[k] * (b - a)
        return tot
    lo, hi = -6, int(rst - cut) + 40
    cb = tc_bins(tc_series(r['tcs']['client']), cut, lo, hi)
    sb = tc_bins(tc_series(r['tcs']['server']), cut, lo, hi)
    rows = []
    for s in range(lo, hi):
        u, d = at(up, s), at(dn, s)
        c = cb.get(s, [(None, 0), (None, 0)]); v = sb.get(s, [(None, 0), (None, 0)])
        rows.append(dict(s=s, up_loss=round(100 * (1 - u / exp), 1), dn_loss=round(100 * (1 - d / exp), 1),
                         p0u=c[0][0], p1u=c[1][0], p1u_drop=c[1][1], p0d=v[0][0], p1d=v[1][0], p1d_drop=v[1][1]))
    R = rst - cut
    name = os.path.basename(f)[4:-5]
    print(f'\n== {name}  cut→restore {R:.1f}s  expected {exp:.0f} pkt/s')
    print(' t(s) | up% dn% | p0↑ p1↑ Mbit (p1↑drop) | p0↓ p1↓ Mbit (p1↓drop)')
    for x in rows:
        mark = ' <cut' if x['s'] == 0 else (' <restore' if x['s'] == int(R) else '')
        print(f"{x['s']:5d} | {x['up_loss']:5.1f} {x['dn_loss']:5.1f} | {x['p0u']} {x['p1u']} ({x['p1u_drop']}) | {x['p0d']} {x['p1d']} ({x['p1d_drop']}){mark}")
    pre = [x for x in rows if -5 <= x['s'] < 0]
    p0u_pre = sum(x['p0u'] or 0 for x in pre) / max(1, len(pre)); p0d_pre = sum(x['p0d'] or 0 for x in pre) / max(1, len(pre))
    after = [x for x in rows if x['s'] >= int(R) + 1 and x['s'] < hi - 3]
    def first(cond, xs):
        for x in xs:
            if cond(x): return x['s']
    lossy = lambda k: [x['s'] for x in rows if x[k] > 1.0 and x['s'] < hi - 3]
    summ = dict(run=name, restore_at=round(R, 1),
                up_loss_secs=lossy('up_loss'), dn_loss_secs=lossy('dn_loss'),
                cut_lost_up_pkts=round(sum(max(0, exp * x['up_loss'] / 100) for x in rows if 0 <= x['s'] < int(R))),
                cut_lost_dn_pkts=round(sum(max(0, exp * x['dn_loss'] / 100) for x in rows if 0 <= x['s'] < int(R))),
                after_lost_up_pkts=round(sum(max(0, exp * x['up_loss'] / 100) for x in rows if int(R) <= x['s'] < hi - 3)),
                after_lost_dn_pkts=round(sum(max(0, exp * x['dn_loss'] / 100) for x in rows if int(R) <= x['s'] < hi - 3)),
                p0u_pre=round(p0u_pre, 2), p0d_pre=round(p0d_pre, 2),
                p0u_back_s=first(lambda x: (x['p0u'] or 0) >= 0.5 * p0u_pre, [x for x in rows if x['s'] >= int(R)]),
                p0d_back_s=first(lambda x: (x['p0d'] or 0) >= 0.5 * p0d_pre, [x for x in rows if x['s'] >= int(R)]),
                p1u_drops_total=sum(x['p1u_drop'] for x in rows), p1d_drops_total=sum(x['p1d_drop'] for x in rows))
    summary.append(summ); print('SUMMARY', json.dumps(summ))
json.dump(summary, open(os.path.join(D, 'summary.json'), 'w'), indent=1)
