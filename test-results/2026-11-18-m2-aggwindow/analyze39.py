#!/usr/bin/env python3
# run39 1초 정렬: iperf3 초당 처리량·재전송(송신측) + mf 카운터 증분(client/server) + Udp Rcvbuf/Sndbuf 증분(.92/.93)
import re, sys, os
D = os.path.dirname(os.path.abspath(__file__))
out = open(f'{D}/run39.out').read()
runs = re.findall(r'  (\S+) start (\d+)\n  \1 end   (\d+)', out)
def stat(path, keys):
    rows = []
    for l in open(path, errors='replace'):
        m = re.search(r'\[stat1s\] ms=(\d+) (.*) q=(\d+)', l)
        if m:
            kv = dict(x.split('=') for x in m.group(2).split())
            rows.append((int(m.group(1)), [int(kv[k]) for k in keys], int(m.group(3))))
    return rows
CK = ['eagain', 'over', 'stale', 'flushed', 'senderr']; SK = ['enq', 'full', 'stale', 'flushed', 'senderr']
def delta_at(rows, t0, t1):  # 누적값 차: t0 이후 첫 표본 ~ t1 이후 첫 표본
    a = next((r for r in rows if r[0] >= t0), None); b = next((r for r in rows if r[0] >= t1), None)
    if not a or not b: return None
    return [y - x for x, y in zip(a[1], b[1])], b[2]
def udp(path):
    return [tuple(map(int, l.split())) for l in open(path) if len(l.split()) == 3]
def iperf_int(name, dn):
    txt = open(f'{D}/raw39/iperf_{name}.txt').read()
    if dn:  # 송신측 = 서버 출력
        txt = txt.split('Server output:')[-1]
    P1 = '-P 1' in name or '_p1_' in name
    pat = (r'\[SUM\]\s+([\d.]+)-([\d.]+)\s+sec\s+\S+ \S+\s+([\d.]+) (\w)bits/sec\s+(\d+)' if not P1 else
           r'\[\s*\d+\]\s+([\d.]+)-([\d.]+)\s+sec\s+\S+ \S+\s+([\d.]+) (\w)bits/sec\s+(\d+)')
    res = []
    for m in re.finditer(pat, txt):
        s, e = float(m.group(1)), float(m.group(2))
        if e - s > 1.5: continue
        v = float(m.group(3)) * (1000 if m.group(4) == 'G' else 1 if m.group(4) == 'M' else 0.001)
        res.append((s, v, int(m.group(5))))
    return res
tot = {}
for name, t0, t1 in runs:
    t0 = int(t0); dn = '_dn' in name
    var = name.rsplit('_', 2)[0]
    cst = stat(f'{D}/raw39/92/client_r39_{var}.log', CK); sst = stat(f'{D}/raw39/93/server_r39_{var}.log', SK)
    ints = iperf_int(name, dn)
    cu = udp(f'{D}/raw39/92/r39_{name}_udp.txt'); su = udp(f'{D}/raw39/93/r39_{name}_udp.txt')
    print(f'\n== {name} ({"하향 server→client" if dn else "상향 client→server"})')
    print(' 초 | Mbps | 재전송 | c.EAGAIN c.넘침 c.stale c.flushed c.q | s.EAGAIN s.넘침 s.stale s.flushed s.q | rcvbufErr c/s | sndbufErr c/s')
    T = [0] * 13; e3 = 0
    for s, mbps, retr in ints:
        a = t0 + 1000 + int(s * 1000); b = a + 1000   # 연결 수립 ~1초 보정(대략)
        c = delta_at(cst, a, b); v = delta_at(sst, a, b)
        def ud(rows):
            x = next((r for r in rows if r[0] >= a), None); y = next((r for r in rows if r[0] >= b), None)
            return (y[1] - x[1], y[2] - x[2]) if x and y else (0, 0)
        cr, cs = ud(cu); sr, ss = ud(su)
        cc = c[0] if c else [0]*5; vv = v[0] if v else [0]*5
        print(f' {s:4.0f} | {mbps:5.1f} | {retr:5d} | {cc[0]:6d} {cc[1]:6d} {cc[2]:5d} {cc[3]:7d} {c[1] if c else 0:4d} | {vv[0]:6d} {vv[1]:6d} {vv[2]:5d} {vv[3]:7d} {v[1] if v else 0:4d} | {cr:5d}/{sr:5d} | {cs}/{ss}')
        e3 += retr if s <= 2 else 0
        for i, x in enumerate([mbps, retr] + cc[:4] + vv[:4] + [cr, sr, cs + ss]): T[i] += x
    n = len(ints) or 1
    print(f' 합 | 평균 {T[0]/n:.1f} | {T[1]} | {T[2]} {T[3]} {T[4]} {T[5]} | {T[6]} {T[7]} {T[8]} {T[9]} | {T[10]}/{T[11]} | {T[12]}')
    tot[name] = (T, n, e3)

print('\n== 요약 (런별 합) — Mbps 평균 | 재전송 처음3초/나머지 | c.EAGAIN c.넘침 | s.EAGAIN s.넘침+stale | rcvbufErr c/s')
for name, (T, n, e3) in tot.items():
    print(f' {name:22s} {T[0]/n:6.1f} | {e3:5d}/{T[1]-e3:5d} | {T[2]:6d} {T[3]:5d} | {T[6]:6d} {T[7]+T[8]:5d} | {T[10]}/{T[11]}')
