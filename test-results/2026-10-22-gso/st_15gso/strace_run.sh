#!/bin/bash
# strace_run.sh — 15 Mbps 양방향 부하 중 c·s multi-fec 의 시스템 호출 수 (2026-10-22, 테스트망 전용)
# 바이너리·유닛 무변경. 가드 선기동(GW_NET=new). strace 가 붙은 15초는 호출 "횟수" 용 — 처리량·CPU 로 쓰지 않는다.
set -u
cd "$(dirname "$0")"
G=../../2026-08-02-50mbps-soak/mf_gwguard.sh
C=root@192.168.100.92; S=root@192.168.100.102
RATE=${RATE:-15}; DUR=60; AT=20; ST=15
export GW_NET=new GW_PROFILE=vm
setsid "$G" watch "mfgen tx" > guard.log 2>&1 < /dev/null & GP=$!
sleep 12; kill -0 $GP 2>/dev/null && grep -q '감시 시작' guard.log || { echo "가드 기동 실패"; cat guard.log; exit 2; }
trap 'kill $GP 2>/dev/null; pkill -P $GP 2>/dev/null' EXIT
echo "[$(date +%T)] 가드 감시 중 · $(systemctl show multi-fec-server -p MainPID --value) (sv1 운영 PID)"
CP=$(ssh $C 'systemctl show -p MainPID --value multi-fec@client'); SP=$(ssh $S 'systemctl show -p MainPID --value multi-fec@server')
echo "client PID $CP · server PID $SP"
ssh $S "mfgen rx 10.9.20.1 5301 $((DUR+4)) > /tmp/st_up.txt" & R1=$!
ssh $C "mfgen rx 10.9.20.2 5302 $((DUR+4)) > /tmp/st_dn.txt" & R2=$!
sleep 1
ssh $C "mfgen tx 10.9.20.1 5301 $RATE $DUR" > tx_up.txt 2>&1 & T1=$!
ssh $S "mfgen tx 10.9.20.2 5302 $RATE $DUR" > tx_dn.txt 2>&1 & T2=$!
sleep $AT
ssh $C "timeout -s INT $ST strace -c -f -p $CP -o /tmp/strace_c.txt" & A1=$!
ssh $S "timeout -s INT $ST strace -c -f -p $SP -o /tmp/strace_s.txt" & A2=$!
wait $A1; wait $A2
wait $T1; wait $T2; wait $R1; wait $R2
scp -q $C:/tmp/strace_c.txt strace_client.txt; scp -q $S:/tmp/strace_s.txt strace_server.txt
scp -q $S:/tmp/st_up.txt mfgen_up.txt; scp -q $C:/tmp/st_dn.txt mfgen_dn.txt
ssh $C 'rm -f /tmp/strace_c.txt /tmp/st_dn.txt'; ssh $S 'rm -f /tmp/strace_s.txt /tmp/st_up.txt'
grep -q 트립 guard.log && echo "가드 트립!"
echo "up: $(grep ^total mfgen_up.txt)"; echo "dn: $(grep ^total mfgen_dn.txt)"
echo "[$(date +%T)] STRACE_DONE"
