#!/usr/bin/env python3
"""lat_episodes.py — 200 ms 넘는 ping 을 송신 시각 기준 0.5 s 안으로 묶어 "사건" 으로 센다 (2026-10-18, REPORT §16-4)
   python3 lat_episodes.py raw/mb_soak/B4096 raw/cmp_soak/B ...   (ping_load.txt + steps.txt)"""
import re, sys
L=re.compile(r'^\[(\d+\.\d+)\].*icmp_seq=(\d+).*time=([\d.]+) ms')
for d in sys.argv[1:]:
    pl=[(float(m[1]),int(m[2]),float(m[3])) for l in open(d+'/ping_load.txt',errors='replace') if (m:=L.match(l))]
    steps=[l.split() for l in open(d+'/steps.txt')]
    for rate,a,b in steps:
        v=[x for x in pl if float(a)<=x[0]<=float(b)]
        seqs={s for _,s,_ in v}; lost=sorted(set(range(min(seqs),max(seqs)+1))-seqs)
        slow=[x for x in v if x[2]>200]
        # episodes: group slow by send time (arrival-rtt) within 0.5s
        ep=[];
        for t,s,r in sorted(slow,key=lambda x:x[0]-x[2]/1000):
            st=t-r/1000
            if ep and st-ep[-1]['end']<0.5: ep[-1]['end']=st; ep[-1]['n']+=1; ep[-1]['max']=max(ep[-1]['max'],r); ep[-1]['arr'].append(t)
            else: ep.append(dict(start=st,end=st,n=1,max=r,arr=[t]))
        dur=(float(b)-float(a))/60
        big=[e for e in ep if e['max']>500]
        spread=[max(e['arr'])-min(e['arr']) for e in big]
        print(f"{d.split('/')[-1]:10s} {rate:>2}Mbps {dur:.0f}min 사건{len(ep):3d} (>500ms {len(big):2d}) 분당{len(ep)/dur:4.1f}  최대 {max([e['max'] for e in ep] or [0]):6.0f}  사건당 ping {sum(e['n'] for e in ep)/max(1,len(ep)):4.1f}  >500ms 도착폭 {('%.2f' % max(spread)) if spread else '-'}s  손실 {len(lost)}")
