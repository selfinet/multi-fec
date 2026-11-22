#!/usr/bin/env python3
# run41 집계: 단계별 H(3대) 수신 Mbps · L(27명) 수신 분포 · ping p50/p95/p99
import re, glob, os, statistics as st, sys
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(__file__), 'raw41/92/r41')
def val(num, unit):
    v = float(num); return v*1000 if unit.startswith('G') else v/1000 if unit.startswith('K') else v
rx = re.compile(r'([\d.]+)-([\d.]+)\s+sec\s+[\d.]+ \w?Bytes\s+([\d.]+) (\w?)bits/sec')
def summary(f):
    ls = [l for l in open(f) if 'receiver' in l and rx.search(l)]
    sums = [l for l in ls if l.startswith('[SUM]')]
    l = (sums or ls or [None])[-1]
    if l is None: return None
    m = rx.search(l); return val(m.group(3), m.group(4))
def window(f, a, b):
    xs = []
    for l in open(f):
        if l.startswith('[SUM]') and 'receiver' not in l and 'sender' not in l:
            m = rx.search(l)
            if m and a <= float(m.group(1)) < b: xs.append(val(m.group(3), m.group(4)))
    return st.mean(xs) if xs else None
def ping(fs):
    t = sorted(float(x) for f in fs for x in re.findall(r'time=([\d.]+)', open(f).read()))
    if not t: return 'ping 없음'
    q = lambda p: t[min(len(t)-1, int(len(t)*p))]
    sent = sum(int(m) for f in fs for m in re.findall(r'(\d+) packets transmitted', open(f).read()))
    return f'ping p50 {q(.5):.0f} p95 {q(.95):.0f} p99 {q(.99):.0f} max {t[-1]:.0f} ms (n={len(t)}/{sent})'
names = sorted({os.path.basename(f).rsplit('_', 1)[0] for f in glob.glob(f'{D}/*_H1.txt')},
               key=lambda n: (['nocake_1','cake_1','cake_2','nocake_2'].index(n.rsplit('_',1)[0]), ['heavy','cap','free'].index(n.rsplit('_',1)[1])))
for n in names:
    H = [f'{D}/{n}_H{i}.txt' for i in (1, 2, 3)]
    if n.endswith('heavy'):
        hv = [summary(f) or 0 for f in H]
        print(f'{n:16s} H {"/".join(f"{x:.0f}" for x in hv)} 합 {sum(hv):.0f} | {ping(glob.glob(f"{D}/{n}_P*.txt"))}')
        continue
    hv = [window(f, 7, 33) or 0 for f in H]
    L = [summary(f'{D}/{n}_L{j}.txt') for j in range(14, 41)]
    bad = sum(1 for x in L if x is None); L = sorted(x for x in L if x is not None)
    low = sum(1 for x in L if x < 3.6) if n.endswith('cap') else None
    jain = sum(L)**2 / (len(L)*sum(x*x for x in L)) if L else 0
    print(f'{n:16s} H(7~33 s) {"/".join(f"{x:.0f}" for x in hv)} 합 {sum(hv):.0f} | L {len(L)}명 합 {sum(L):.0f} 최소 {L[0]:.2f} 중앙 {st.median(L):.2f} 최대 {L[-1]:.2f}'
          + (f' <3.6M {low}명' if low is not None else f' Jain {jain:.2f}') + (f' 실패 {bad}' if bad else '')
          + f' | 사용자당 H {sum(hv)/3:.1f} vs L {sum(L)/len(L):.1f} | {ping(glob.glob(f"{D}/{n}_P*.txt"))}')
