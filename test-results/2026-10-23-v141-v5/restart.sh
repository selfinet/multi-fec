#!/bin/bash
# restart.sh — 프로세스 재시작 복구 시험 (2026-10-23, 테스트망 전용, 4대)
# 전 호스트를 같은 버전으로 두고 WG 위 mfgen 양방향 RATE Mbps, DUR 초 동안 차례로 재시작:
#   t=20 s multi-fec@server · t=50 c multi-fec@client · t=80 rs2 multi-fec@relay(path[1]) · t=110 r multi-fec@relay(path[0])
# 산출: raw/rst_<ver>_<rep>/{up,dn}.txt(초당) · events.txt · guard.log. 끝나면(중단돼도) 4대 .v1.4.0 복원
set -u
cd "$(dirname "$0")"
G=../2026-08-02-50mbps-soak/mf_gwguard.sh
C=root@192.168.100.92; R=root@192.168.100.88; R2=root@192.168.100.131; S=root@192.168.100.102
RATE=${RATE:-10}; DUR=${DUR:-150}; REPS=${REPS:-2}; VERS=${VERS:-"1.4.0 1.4.1-v5"}
export GW_NET=new GW_PROFILE=vm
inst() { ssh "$1" "install -m 755 /usr/sbin/multi-fec-dist.v$3 /usr/sbin/multi-fec-dist && systemctl restart $2"; }
setall() { inst $S multi-fec@server $1; inst $R multi-fec@relay $1; inst $R2 multi-fec@relay $1; inst $C multi-fec@client $1
  for i in $(seq 1 12); do ssh $C 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done; sleep 15; }
GP=
fin() { echo "[$(date +%T)] ===== 정리 · 1.4.0 복원"; [ -n "$GP" ] && { kill $GP 2>/dev/null; pkill -P $GP 2>/dev/null; }
  setall 1.4.0
  for h in $C $R $R2 $S; do ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@server 2>/dev/null | tr "\n" " ")"'; done
  ssh $C 'ping -c 5 -i 0.3 -W 1 -q 10.9.20.1 | tail -1'; }
trap fin EXIT
setsid "$G" watch "mfgen tx" > raw/rst_guard.log 2>&1 < /dev/null & GP=$!
sleep 12; kill -0 $GP 2>/dev/null && grep -q '감시 시작' raw/rst_guard.log || { echo "가드 기동 실패"; exit 2; }
for rep in $(seq 1 $REPS); do for v in $VERS; do
  O=raw/rst_${v//[.-]/}_$rep; mkdir -p $O
  echo "[$(date +%T)] ##### restart v$v rep$rep"; setall $v
  kill -0 $GP 2>/dev/null || { echo "가드 소멸(트립?)"; exit 3; }
  ssh $S "mfgen rx 10.9.20.1 5301 $((DUR+6)) > /tmp/rst_up.txt" >/dev/null 2>&1 & A1=$!
  ssh $C "mfgen rx 10.9.20.2 5302 $((DUR+6)) > /tmp/rst_dn.txt" >/dev/null 2>&1 & A2=$!
  sleep 1; T0=$(date +%s)
  ssh $C "mfgen tx 10.9.20.1 5301 $RATE $DUR" >/dev/null 2>&1 & B1=$!
  ssh $S "mfgen tx 10.9.20.2 5302 $RATE $DUR" >/dev/null 2>&1 & B2=$!
  ev() { sleep $(( $1 - ($(date +%s) - T0) )); ssh $2 "systemctl restart $3"; echo "$(( $(date +%s) - T0 )) $4" >> $O/events.txt; }
  ev 20 $S multi-fec@server server; ev 50 $C multi-fec@client client; ev 80 $R2 multi-fec@relay relay-rs2; ev 110 $R multi-fec@relay relay-r
  wait $B1; wait $B2; wait $A1; wait $A2
  scp -q $S:/tmp/rst_up.txt $O/up.txt; scp -q $C:/tmp/rst_dn.txt $O/dn.txt
  ssh $C "journalctl -u multi-fec@client --since @$T0 --no-pager -o short-unix" | sed 's/\x1b\[[0-9;]*m//g' > $O/cli.log
  ssh $S "journalctl -u multi-fec@server --since @$T0 --no-pager -o short-unix" | sed 's/\x1b\[[0-9;]*m//g' > $O/srv.log
  python3 - $O <<'PY'
import sys,re
o=sys.argv[1]; ev=[l.split() for l in open(o+'/events.txt')]
def load(f):
    d={}
    for l in open(f):
        m=re.match(r'sec (\d+) rx (\d+) lost (-?\d+)',l)
        if m: d[int(m.group(1))]=(int(m.group(2)),int(m.group(3)))
    tot=[l for l in open(f) if l.startswith('total')]
    return d,(tot[0].split()[-5] if tot else '?')
for dirn in ('up','dn'):
    d,lp=load(f'{o}/{dirn}.txt'); xs=sorted(v[0] for k,v in d.items() if 5<k<15); nom=xs[len(xs)//2] if xs else 1
    parts=[]
    for t,name in ev:
        t=int(t); w=[d.get(t+i,(0,0)) for i in range(0,15)]
        low=sum(1 for rx,_ in w if rx<0.5*nom); lost=sum(max(0,l) for _,l in w)
        parts.append(f'{name}: 반토막초 {low} 손실 {lost}')
    print(f'[rst] {o.split("/")[-1]} {dirn} 전체손실 {lp}% | '+' · '.join(parts))
PY
  sleep 10
done; done
grep -q 트립 raw/rst_guard.log && echo "[rst] 가드 트립"
echo "[$(date +%T)] RESTART_DONE"
