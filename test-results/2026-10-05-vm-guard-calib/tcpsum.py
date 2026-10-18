#!/usr/bin/env python3
"""tcpsum.py — iperf3 -J 한 개를 한 줄로: 수신 goodput · 재전송 · 송신측 TCP RTT(평균/최대) (2026-10-17)"""
import json, sys
try:
    e = json.load(open(sys.argv[1]))
    end, st = e['end'], e['end']['streams'][0]['sender']
    print('%.2fMbps rtx=%s srtt=%.0f/%.0fms' % (end['sum_received']['bits_per_second'] / 1e6,
          end['sum_sent'].get('retransmits', '?'), st.get('mean_rtt', 0) / 1000, st.get('max_rtt', 0) / 1000))
except Exception as x:
    print('ERR', type(x).__name__)
