import re,sys
def load(p):
    t=open(p).read(); sec={}; cur=None
    for l in t.splitlines():
        if l.startswith('#kernel'): continue
        if l.startswith('#'): cur=l[1:]; sec[cur]=[]; continue
        if cur: sec[cur].append(l)
    out={}
    for l in sec['NSTAT']:
        f=l.split()
        if len(f)>=2 and f[1].isdigit(): out['n.'+f[0]]=int(f[1])
    for name in ('LINK_ENP','LINK_WG'):
        L=sec[name]
        for i,l in enumerate(L):
            s=l.strip()
            if s.startswith('RX:') and 'bytes' in s: v=L[i+1].split(); out[name+'.rx_pk']=int(v[1]); out[name+'.rx_err']=int(v[2]); out[name+'.rx_drop']=int(v[3])
            if s.startswith('TX:') and 'bytes' in s: v=L[i+1].split(); out[name+'.tx_pk']=int(v[1]); out[name+'.tx_err']=int(v[2]); out[name+'.tx_drop']=int(v[3])
    for name in ('TC_ENP','TC_WG'):
        q=None
        for l in sec[name]:
            m=re.match(r'qdisc (\S+) (\S+)',l)
            if m: q=m.group(1)+m.group(2)
            m=re.search(r'Sent \d+ bytes (\d+) pkt \(dropped (\d+), overlimits (\d+)',l)
            if m and q: out[f'{name}.{q}.sent']=int(m.group(1)); out[f'{name}.{q}.drop']=int(m.group(2))
    for l in sec['UDP'][1:]:
        f=l.split(); lp=int(f[1].split(':')[1],16); out[f'udp.{lp}.drops']=out.get(f'udp.{lp}.drops',0)+int(f[-1])
    for l in sec['ETH']:
        f=l.split(':')
        if len(f)==2 and f[1].strip().isdigit(): out['eth.'+f[0].strip()]=int(f[1])
    return out
keys=['LINK_WG.tx_pk','LINK_WG.rx_pk','LINK_WG.rx_err','LINK_WG.rx_drop','LINK_WG.tx_drop','LINK_ENP.tx_pk','LINK_ENP.rx_pk','LINK_ENP.rx_drop','LINK_ENP.tx_drop',
 'n.UdpInDatagrams','n.UdpRcvbufErrors','n.UdpSndbufErrors','n.UdpInErrors','n.TcpRetransSegs','n.TcpExtTCPDSACKRecv','n.TcpExtTCPDSACKOldSent','n.TcpExtTCPDSACKOfoRecv',
 'n.TcpExtTCPSACKReorder','n.TcpExtTCPTSReorder','n.TcpExtTCPLostRetransmit','n.TcpExtTCPSpuriousRTOs','n.TcpExtTCPTimeouts','n.TcpExtTCPFastRetrans','n.TcpExtTCPOFOQueue','n.TcpExtTCPLossProbes',
 'n.TcpExtTCPFullUndo','n.TcpExtTCPPartialUndo','n.TcpExtTCPDSACKUndo','n.TcpExtTCPSACKReneging','n.IpExtInNoRoutes','n.IpInDiscards','n.IpOutDiscards']
for r in sys.argv[1:]:
    print(f'===== {r}')
    for h in ('92','93'):
        a=load(f'raw5/snap_{r}_a_{h}.txt'); b=load(f'raw5/snap_{r}_b_{h}.txt')
        d={k:b[k]-a.get(k,0) for k in b}
        extra=[k for k in d if (k.startswith('TC_') or k.startswith('udp.') or k.startswith('eth.')) and d[k]]
        print(f'-- .{h}: '+'  '.join(f'{k.replace("n.","").replace("TcpExt","")}={d[k]}' for k in keys if d.get(k)))
        print('   '+'  '.join(f'{k}={d[k]}' for k in sorted(extra)))
