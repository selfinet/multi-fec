#!/usr/bin/env python3
"""lat_tail.py — 지속 구간 터널 ping 을 '손실' 과 '지연' 으로 나눠 센다 (2026-10-09)

  python3 lat_tail.py raw/cmp_soak/A raw/cmp_soak/B ...

버퍼가 크면 같은 교란이 손실 대신 지연으로 나타난다. 둘을 합쳐야 버퍼 크기 간 비교가 공정하다.
손실은 icmp_seq 빈 번호, 지연은 RTT > 200 ms(기준 53 ms 의 약 4배) 인 응답 수.
steps.txt(`레이트 t0 t1`) 구간에 드는 응답만 그 레이트로 센다 — lat_analyze.py 와 같은 규칙.
"""
import re, sys

LINE = re.compile(r'^\[(\d+\.\d+)\].*icmp_seq=(\d+).*time=([\d.]+) ms')

for d in sys.argv[1:]:
    steps = [l.split() for l in open(d + '/steps.txt')]
    ping = [(float(m[1]), int(m[2]), float(m[3]))
            for l in open(d + '/ping_load.txt', errors='replace') if (m := LINE.match(l))]
    print(f'== {d}')
    for rate, a, b in steps:
        rows = [(s, r) for t, s, r in ping if float(a) <= t <= float(b)]
        if not rows:
            continue
        seqs = {s for s, _ in rows}
        sent = max(seqs) - min(seqs) + 1
        lost = sent - len(seqs)
        slow = sum(1 for _, r in rows if r > 200)
        vslow = sum(1 for _, r in rows if r > 1000)
        print(f'  {rate:>3} Mbps  보낸 {sent:6d}  손실 {lost:4d}  >200ms {slow:4d}  >1s {vslow:3d}'
              f'  손실+지연 {lost + slow:4d} ({100 * (lost + slow) / sent:.2f}%)')
