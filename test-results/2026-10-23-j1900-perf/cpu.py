import csv,sys,statistics
o=sys.argv[1]; out=[]
for h in ('c','s'):
    try: rows=list(csv.DictReader(open(f'{o}/hs_{h}.csv')))
    except Exception: continue
    x=[r for r in rows if float(r['mbps'])>1][3:-3] or rows
    m=lambda k: statistics.median(float(r[k]) for r in x)
    out.append(f"{h}: tot {m('tot'):.0f}% max {m('max'):.0f}% mf {m('mf_cpu'):.0f}% nic {m('mbps'):.0f}")
print(' | '.join(out))
