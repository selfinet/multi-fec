#!/bin/bash
# mpstat_run.sh — 15 Mbps 양방향 부하 중 c·s 코어별 사용률과 multi-fec·WG 작업자 위치 (2026-10-22, 테스트망 전용)
# 바이너리·유닛 무변경. 가드 선기동(GW_NET=new).
set -u
cd "$(dirname "$0")"
G=../2026-08-02-50mbps-soak/mf_gwguard.sh
C=root@192.168.100.92; S=root@192.168.100.102
RATE=${RATE:-15}; DUR=60; AT=20; N=30
export GW_NET=new GW_PROFILE=vm
setsid "$G" watch "mfgen tx" > guard.log 2>&1 < /dev/null & GP=$!
sleep 12; kill -0 $GP 2>/dev/null && grep -q '감시 시작' guard.log || { echo "가드 기동 실패"; cat guard.log; exit 2; }
trap 'kill $GP 2>/dev/null; pkill -P $GP 2>/dev/null' EXIT
CP=$(ssh $C 'systemctl show -p MainPID --value multi-fec@client'); SP=$(ssh $S 'systemctl show -p MainPID --value multi-fec@server')
echo "[$(date +%T)] 가드 감시 중 · client PID $CP · server PID $SP"
ssh $S "mfgen rx 10.9.20.1 5301 $((DUR+4)) > /tmp/mp_up.txt" & R1=$!
ssh $C "mfgen rx 10.9.20.2 5302 $((DUR+4)) > /tmp/mp_dn.txt" & R2=$!
sleep 1
ssh $C "mfgen tx 10.9.20.1 5301 $RATE $DUR" > /dev/null 2>&1 & T1=$!
ssh $S "mfgen tx 10.9.20.2 5302 $RATE $DUR" > /dev/null 2>&1 & T2=$!
sleep $AT
meas() { # host pid tag
  ssh $1 "LC_ALL=C mpstat -P ALL 1 $N > /tmp/mp_cpu.txt & LC_ALL=C pidstat -u -h -p $2 1 $N > /tmp/mp_pid.txt &
    for i in \$(seq 1 $N); do ps -eLo psr,comm | awk '/wg-crypt/ {c[\$1]++} END{for (k in c) printf \"%s:%d \", k, c[k]; print \"\"}' >> /tmp/mp_wg.txt; ps -o psr= -p $2 >> /tmp/mp_mfpsr.txt; sleep 1; done; wait"
  scp -q $1:/tmp/mp_cpu.txt mpstat_$3.txt; scp -q $1:/tmp/mp_pid.txt pidstat_$3.txt; scp -q $1:/tmp/mp_wg.txt wgworkers_$3.txt; scp -q $1:/tmp/mp_mfpsr.txt mfpsr_$3.txt
  ssh $1 'rm -f /tmp/mp_cpu.txt /tmp/mp_pid.txt /tmp/mp_wg.txt /tmp/mp_mfpsr.txt'
}
meas $C $CP client & M1=$!
meas $S $SP server & M2=$!
wait $M1; wait $M2
wait $T1; wait $T2; wait $R1; wait $R2
scp -q $S:/tmp/mp_up.txt mfgen_up.txt; scp -q $C:/tmp/mp_dn.txt mfgen_dn.txt; ssh $S 'rm -f /tmp/mp_up.txt'; ssh $C 'rm -f /tmp/mp_dn.txt'
grep -q 트립 guard.log && echo "가드 트립!"
echo "up: $(grep ^total mfgen_up.txt)"; echo "dn: $(grep ^total mfgen_dn.txt)"
echo "[$(date +%T)] MPSTAT_DONE"
