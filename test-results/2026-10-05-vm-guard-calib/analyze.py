#!/usr/bin/env python3
"""analyze.py <raw/RUNID> [skip_head_s]  — 스텝별 호스트 부하 분포 + 초 단위 손실."""
import sys, csv, re, statistics as st
D=sys.argv[1]; SKIP=float(sys.argv[2]) if len(sys.argv)>2 else 8
def load(h):
    with open(f"{D}/hs_{h}.csv") as f: return [{k:float(v) for k,v in r.items()} for r in csv.DictReader(f)]
H={h:load(h) for h in "crs"}
steps=[l.split() for l in open(f"{D}/steps.txt")]
def pct(a,q): a=sorted(a); return a[min(len(a)-1,int(q*len(a)))] if a else float('nan')
def perint(path, tag):
    # per-second receiver lines: "[  5][RX-C]   3.00-4.00 sec ... lost/total (x%)" (client dn) ; server: up
    out=[]
    for l in open(path):
        m=re.search(r'\]\s*(?:\[(..)-[CS]\])?\s+(\d+\.\d+)-(\d+\.\d+)\s+sec.*?(\d+)/(\d+)\s+\(([\d.e+-]+)%\)',l)
        if m and 'receiver' not in l and 'sender' not in l and (tag is None or m.group(1)==tag):
            a,b=float(m.group(2)),float(m.group(3))
            if b-a<=1.01: out.append((a,int(m.group(4)),int(m.group(5))))
    return out
print(f"{'R':>3} {'host':4} {'tot mean/p95/max':>18} {'core mean/p95/max':>19} {'sirq p95':>8} {'steal':>5} {'Mbps':>6} {'mf%':>5}")
for r,t0,t1 in steps:
    t0=float(t0)+SKIP; t1=float(t1)-2
    for h in "crs":
        w=[x for x in H[h] if t0<=x['t']<=t1]
        if not w: continue
        T=[x['tot'] for x in w]; M=[x['max'] for x in w]
        print(f"{r:>3} {h:4} {st.mean(T):5.1f}/{pct(T,.95):5.1f}/{max(T):5.1f} {st.mean(M):6.1f}/{pct(M,.95):5.1f}/{max(M):5.1f} "
              f"{pct([x['sirq_max'] for x in w],.95):8.1f} {st.mean([x['steal_tot'] for x in w]):5.1f} {st.mean([x['mbps'] for x in w]):6.1f} {st.mean([x['mf_cpu'] for x in w]):5.1f}")
    for d in ("up","dn"):
        try: L=[l.split() for l in open(f"{D}/{d}_{r}.txt")]
        except FileNotFoundError: continue
        sec=[(int(x[1]),int(x[5])) for x in L if x[0]=="sec"]; tot=[x for x in L if x[0]=="total"]
        bad=[(a,b) for a,b in sec if b>0]
        print(f"    {d} 손실 {tot[0][8] if tot else '?'}%  ooo {tot[0][12] if tot else '?'}  손실>0 초 {len(bad)}/{len(sec)}: "+" ".join(f"{a}s:{b}" for a,b in bad[:10]))
