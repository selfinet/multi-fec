#!/usr/bin/env python3
"""replay.py — 기록된 1초 샘플을 가드 판정(호스트별 전체·최고1코어, 연속 N회)으로 재생해 최대 연속을 센다."""
import csv, sys
RUNS=sys.argv[1:]
CANDS=[(80,83,92,3),(85,88,95,3),(85,88,95,5),(88,90,97,5)]   # (c전체, r·s전체, 1코어, streak)
def load(run,h): return [{k:float(v) for k,v in r.items()} for r in csv.DictReader(open(f"raw/{run}/hs_{h}.csv"))]
print("run      " + "  ".join(f"c{a}/vm{b}/core{c}/s{n}" for a,b,c,n in CANDS))
for run in RUNS:
    H={h:load(run,h) for h in "crs"}; n=min(len(v) for v in H.values())
    out=[]
    for a,b,c,need in CANDS:
        mx=st=0
        for i in range(n):
            over=any(H[h][i]['tot']>(a if h=='c' else b) or H[h][i]['max']>c for h in "crs")
            st=st+1 if over else 0; mx=max(mx,st)
        out.append(f"{'트립' if mx>=need else '통과'}({mx})".ljust(len(f"c{a}/vm{b}/core{c}/s{need}")))
    print(f"{run:8} "+"  ".join(out))
