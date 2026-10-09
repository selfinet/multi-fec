#!/usr/bin/env python3
"""lat_analyze.py — tp_ladder.sh PING=1 결과에서 단계별 터널 RTT 분포 (2026-10-06)

  python3 lat_analyze.py raw/lat/P2 raw/lat/P5

ping_idle.txt 는 유휴 기준선, ping_load.txt 는 부하 중 연속 ping(-D epoch).
steps.txt(`레이트 t0 t1`, sv1 시계) 구간에 드는 응답만 그 레이트로 센다 — c 와 sv1 은 NTP 동기라
ms 급 오차는 수 분 구간에 무의미하다. 손실은 icmp_seq 의 빈 번호로 센다.
"""
import re, sys

LINE = re.compile(r'^\[(\d+\.\d+)\].*icmp_seq=(\d+).*time=([\d.]+) ms')

def parse(path):
    rows = []
    try:
        f = open(path, errors='replace')
    except OSError:
        return rows
    for l in f:
        m = LINE.match(l)
        if m:
            rows.append((float(m.group(1)), int(m.group(2)), float(m.group(3))))
    return rows

def pct(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p / 100 * (len(v) - 1))))] if v else float('nan')

def summary(rows, seqs=None):
    rtt = [r[2] for r in rows]
    if not rtt:
        return 'no data'
    lost = ''
    if seqs:
        lo, hi = seqs
        got = {r[1] for r in rows if lo <= r[1] <= hi}
        exp = hi - lo + 1
        lost = f'  loss {100 * (exp - len(got)) / exp:5.2f}%'
    return (f'n={len(rtt):5d}  p50 {pct(rtt, 50):6.1f}  p90 {pct(rtt, 90):6.1f}  '
            f'p99 {pct(rtt, 99):7.1f}  max {max(rtt):7.1f} ms{lost}')

for d in sys.argv[1:]:
    print(f'== {d}')
    idle = parse(f'{d}/ping_idle.txt')
    print(f'  idle     {summary(idle)}')
    load = parse(f'{d}/ping_load.txt')
    try:
        steps = [l.split() for l in open(f'{d}/steps.txt')]
    except OSError:
        steps = []
    for rate, t0, t1 in steps:
        t0, t1 = float(t0) + 5, float(t1) - 2          # 램프·종료 꼬리 제외
        seg = [r for r in load if t0 <= r[0] <= t1]
        rng = (seg[0][1], seg[-1][1]) if seg else None
        print(f'  {rate:>3s} Mbps {summary(seg, rng)}')
