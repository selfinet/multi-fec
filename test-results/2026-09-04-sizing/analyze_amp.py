#!/usr/bin/env python3
"""analyze_amp.py — 증폭 계단 분석. 구간별로 (회선 바이트)/(WG 터널 바이트) 를 낸다.

증폭의 분모를 **WG 터널 인터페이스**로 잡는 이유: 앱 페이로드에 WG/UDP/IP 헤더가 붙은
것이 multi-fec 의 실제 입력이다. 순 페이로드를 분모로 쓰면 WG 오버헤드까지 증폭에
섞여 FEC 기여를 분리할 수 없다.
"""
import sys, re
from collections import defaultdict

path = sys.argv[1] if len(sys.argv) > 1 else 'amp_raw/ifsnap.txt'
snap = {}
for L in open(path):
    p = L.split()
    if len(p) >= 6:
        snap[(p[0], p[1], p[2])] = (int(p[3]), int(p[4]), int(p[5]))

rates = []
for k in snap:
    m = re.fullmatch(r's([0-9.]+)_a', k[0])
    if m and float(m.group(1)) not in rates:
        rates.append(float(m.group(1)))
rates.sort()

def y_of(g):
    return 1 if g <= 5 else 2 if g <= 10 else 3 if g <= 15 else 4

print(f"{'R':>5} {'세션':>4} {'WG터널':>9} {'회선':>9} {'증폭':>7} {'g':>3} {'y':>2} {'이론':>7} {'실측/이론':>9}")
rows = []
for R in rates:
    a, b = f's{R:g}_a', f's{R:g}_b'
    wg = wire = 0.0
    dt = None
    for (lab, h, i), v in snap.items():
        if lab != b or h != 'c': continue
        if (a, h, i) not in snap: continue
        v0 = snap[(a, h, i)]
        d = v[2] - v0[2]
        if d <= 0: continue
        dt = d
        mbps = (v[0] - v0[0] + v[1] - v0[1]) * 8 / d / 1e6
        if i.startswith('mft'): wg += mbps
        elif i == 'enp2s0':     wire += mbps
    if wg <= 0:
        print(f"{R:>5} — 데이터 없음"); continue
    amp = wire / wg
    pps = R * 1e6 / 8 / 1250
    g = min(1 + int(pps * 0.010), 20); y = y_of(g)
    th = (g + y) / g * 2
    print(f"{R:>5g} {'':>4} {wg:>9.2f} {wire:>9.2f} {amp:>7.3f} {g:>3} {y:>2} {th:>7.3f} {amp/th:>9.3f}")
    rows.append((R, wg, wire, amp, g, y, th, amp/th))

if rows:
    ratios = [r[7] for r in rows]
    print(f"\n실측/이론 비율: 최소 {min(ratios):.3f} 최대 {max(ratios):.3f} "
          f"평균 {sum(ratios)/len(ratios):.3f}")
    print("→ 이 비율이 레이트에 무관하게 일정하면 '헤더계수' 하나로 흡수 가능하고,")
    print("  저레이트에서만 크면 그 초과분이 probe 항이다.")
