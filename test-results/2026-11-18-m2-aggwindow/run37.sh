#!/bin/bash
# TCP 시험 중 EAGAIN·pending 1초 단위 (2026-11-20 사용자 "TCP 시험 중 EAGAIN·pending 폐기 1초 단위로 측정해 줘").
# 바이너리: 1.4.5 + 1초 카운터 출력만 추가한 계측 빌드(bin37/mf145i, diff 동봉 — 배포 금지). 조건 run36 과 같음(P0 터널 1, aggregate, 30/54 ms, rps 0, 고정 없음).
# 1초 기록: mf [stat1s](client eagain/over/stale/flushed/senderr/q, server enq/full/stale/flushed/senderr/q) · /proc/net/snmp Udp Rcvbuf/Sndbuf 오류 · iperf3 초당 재전송(송신측).
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw37
restore() { echo "== restore $(date +%T)"
  for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null; pkill -x iperf3; pkill -f '^bash /root/rq/udpsamp37' ; echo 0 > /sys/class/net/lo/queues/rx-0/rps_cpus; sleep 1
    echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) mf=\$(pgrep -fc '^./mf37') iperf=\$(pgrep -xc iperf3) samp=\$(pgrep -fc '^bash /root/rq/udpsamp37')\""; done; }
trap restore EXIT
echo "== setup $(date +%T)"
for h in $C $S; do
  scp -q $J bin37/mf145i $h:/root/rq/mf37.v145i
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    echo 0 > /sys/class/net/lo/queues/rx-0/rps_cpus
    printf "%s\n" "while :; do echo \"\$(date +%s%3N) \$(awk '"'"'/^Udp:/{getline; print \$6, \$7}'"'"' /proc/net/snmp)\"; sleep 1; done" > udpsamp37
    echo "$(hostname) $(sha256sum mf37.v145i | cut -c1-8) $(./mf37.v145i --version | sed -n 2p)"'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s37.log 2>&1 < /dev/null &)'
for pair in "$S server" "$C client"; do set -- $pair
  ssh $J $1 "cd /root/rq; setsid timeout 1800 ./mf37.v145i --config /root/rq/${2}_P0.conf > ${2}_r37.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
sleep 8
ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1"
run() { local name=$1 A=$2
  for h in $C $S; do ssh $J $h "cd /root/rq; (setsid timeout 45 bash /root/rq/udpsamp37 > r37_${name}_udp.txt 2>&1 < /dev/null &)"; done
  echo "  $name start $(date +%s%3N)"
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 -i 1 --get-server-output $A" > raw37/iperf_$name.txt 2>&1
  echo "  $name end   $(date +%s%3N) $(grep -E 'SUM.*receiver|receiver' raw37/iperf_$name.txt | tail -1 | grep -oE '[0-9.]+ Mbits/sec')"; sleep 6; }
for r in 1 2; do run p8_up_$r "-P 8 -t 30"; run p8_dn_$r "-P 8 -t 30 -R"; done
run p1_up "-P 1 -t 30"; run p1_dn "-P 1 -t 30 -R"
for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null"; mkdir -p raw37/${h##*.}; scp -q $J "$h:/root/rq/*_r37.log" "$h:/root/rq/r37_*" raw37/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
