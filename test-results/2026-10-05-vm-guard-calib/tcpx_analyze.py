#!/usr/bin/env python3
"""tcpx_analyze.py — tcpx_1017 TCP 결과 집계 (2026-10-18)
버퍼·레이트·방향별: 수신 goodput, 재전송, 송신측 TCP RTT 평균/최대,
1초 구간 중 목표의 50% 미만인 '끊김' 초 수, 최저 1초 goodput.  + 터널 ping 손실/>200ms/>1s/p99."""
import json, re, glob, collections
L = re.compile(r'^\[(\d+\.\d+)\].*icmp_seq=(\d+).*time=([\d.]+) ms')
A = collections.defaultdict(list)
for d in sorted(glob.glob('raw/tcpx_1017/T*')):
    kb = d.split('/')[-1][1:5]; run = d.split('_')[-1]
    raw = 'raw/tx_' + d.split('/')[-1]
    for r in (10, 20):
        for dr in ('up', 'dn'):
            e = json.load(open(f'{raw}/tcp_{dr}_{r}.json'))
            st = e['end']['streams'][0]['sender']
            iv = [i['sum']['bits_per_second'] / 1e6 for i in e['intervals']]
            A[(kb, r, dr)].append(dict(run=run, gp=e['end']['sum_received']['bits_per_second'] / 1e6,
                rtx=e['end']['sum_sent']['retransmits'], mrtt=st['mean_rtt'] / 1000, xrtt=st['max_rtt'] / 1000,
                stall=sum(v < r * 0.5 for v in iv[1:]), low=min(iv[1:])))
    pl = [(float(m[1]), int(m[2]), float(m[3])) for l in open(d + '/ping_load.txt', errors='replace') if (m := L.match(l))]
    for rate, a, b in (l.split() for l in open(d + '/steps.txt')):
        v = [x for x in pl if float(a) <= x[0] <= float(b)]
        seqs = {s for _, s, _ in v}; rt = sorted(x[2] for x in v)
        A[(kb, int(rate), 'ping')].append(dict(run=run, n=max(seqs) - min(seqs) + 1, lost=max(seqs) - min(seqs) + 1 - len(seqs),
            s200=sum(x > 200 for x in rt), s1=sum(x > 1000 for x in rt), p99=rt[int(.99 * len(rt))], p50=rt[len(rt) // 2]))
for r in (10, 20):
    for kb in ('1024', '4096'):
        for dr in ('up', 'dn'):
            xs = A[(kb, r, dr)]
            print(f'{r:2d}M {kb} {dr}  goodput ' + ' '.join(f"{x['gp']:.2f}" for x in xs)
                  + '  rtx ' + '/'.join(str(x['rtx']) for x in xs) + f" (합 {sum(x['rtx'] for x in xs)})"
                  + '  srtt평균 ' + '/'.join(f"{x['mrtt']:.0f}" for x in xs)
                  + '  srtt최대 ' + '/'.join(f"{x['xrtt']:.0f}" for x in xs)
                  + '  끊김초 ' + '/'.join(str(x['stall']) for x in xs)
                  + '  최저1s ' + '/'.join(f"{x['low']:.1f}" for x in xs))
        xs = A[(kb, r, 'ping')]
        print(f'{r:2d}M {kb} ping  n={sum(x["n"] for x in xs)} 손실 {sum(x["lost"] for x in xs)}  >200 {sum(x["s200"] for x in xs)}  >1s {sum(x["s1"] for x in xs)}  p50 '
              + '/'.join(f"{x['p50']:.1f}" for x in xs) + '  p99 ' + '/'.join(f"{x['p99']:.0f}" for x in xs))
