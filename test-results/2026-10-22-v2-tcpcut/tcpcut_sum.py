#!/usr/bin/env python3
"""tcpcut_sum.py <iperf3 -J> <cut_at> <up_at> — 평균 goodput · 재전송 · 절단 구간(cut~up+10초) 최저 1초 처리량 · 처리량이 상한 절반 아래인 초 수"""
import json, sys
try:
    e = json.load(open(sys.argv[1])); a, b = int(sys.argv[2]), int(sys.argv[3])
    iv = [(x['sum']['start'], x['sum']['bits_per_second'] / 1e6, x['sum'].get('retransmits', 0)) for x in e['intervals']]
    avg = e['end']['sum_received']['bits_per_second'] / 1e6
    rtx = e['end']['sum_sent'].get('retransmits', 0)
    win = [m for t, m, _ in iv if a <= t < b + 10]
    cap = max(m for _, m, _ in iv) if iv else 0
    low = sum(1 for _, m, _ in iv if m < cap / 2)
    print('%.2fMbps rtx=%d 구간최저=%.1f 반토막초=%d' % (avg, rtx, min(win) if win else -1, low))
except Exception as x:
    print('ERR', type(x).__name__)
