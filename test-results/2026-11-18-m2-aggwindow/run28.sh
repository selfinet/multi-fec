#!/bin/bash
# speed.1 단일 연결(-P 1) perf 프로파일 — 기호 있는 static(코드 = d76d9d6), 터널 1개 pin 0 rps e, ue→hq. 2026-11-19 사용자 지시.
# 상·하 각 30 s 중 5~25 s 에 client·server 프로세스 perf record -g(커널 콜체인; 사용자 공간은 프레임 포인터 없어 평면 기호만 믿을 것).
# 같은 구간 perf record -a(시스템 전체, 코어별) 도 따로 한 번.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw28
echo "== setup $(date +%T)"
for h in $C $S; do scp -q $J /home/stevekim/mf-speed/multi-fec-static $h:/root/rq/multi-fec-static.spd1
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    echo "$(hostname) $(md5sum multi-fec-static.spd1 | cut -c1-12 | paste -sd" ")"'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 ip netns exec hq iperf3 -s > iperf_hq24.log 2>&1 < /dev/null &)'

setrps() { for h in $C $S; do ssh $J $h "echo $1 > /sys/class/net/lo/queues/rx-0/rps_cpus"; done; }
route() { local n=$1 nh=""; for k in $(seq 0 $((n-1))); do d=rq-wg; [ $k -gt 0 ] && d=rq-wg$((k+1)); nh="$nh nexthop dev $d"; done
  ssh $J $C "ip route replace 10.90.0.0/24 $nh"; ssh $J $S "ip route replace 10.88.1.0/24 $nh"; }
restore() { echo "== restore $(date +%T)"; setrps 0; route 3
  for h in $C $S; do ssh $J $h "cd /root/rq; for f in *_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; true
    echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) \$(ip route show 10.90.0.0/24 | wc -l)/\$(ip route show 10.88.1.0/24 | wc -l) mf=\$(pgrep -c multi-fec-dist)\""; done; }
trap restore EXIT

start() { local v=$1 n=$2 pins=$3 bin=$4
  read -ra P <<< "$pins"
  for pair in "$S server" "$C client"; do set -- $pair
    cmd="cd /root/rq; for f in ${2}_P?.pid; do kill \$(cat \$f) 2>/dev/null; done; sleep 1"
    for k in $(seq 0 $((n-1))); do pc=""; [ -n "${P[$k]:-}" ] && pc="--pin-cpu ${P[$k]}"
      cmd="$cmd; setsid timeout 1200 ./multi-fec-$bin --config /root/rq/${2}_P$k.conf $pc > ${2}_P${k}_r28_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P$k.pid"; done
    ssh $J $1 "$cmd"; done
  sleep 10
  ssh $J $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; for k in \$(seq 0 $((n-1))); do echo -n \"P\$k \$(taskset -pc \$(pgrep -P \$(cat /root/rq/client_P\$k.pid)) | awk '{print \$NF}') \"; done; echo; cat /sys/class/net/lo/queues/rx-0/rps_cpus"; }

CNT='for i in rq-wg rq-wg2 rq-wg3; do echo -n "$(cat /sys/class/net/$i/statistics/tx_packets) $(cat /sys/class/net/$i/statistics/rx_packets) "; done'
run() { local name=$1 P=$2 A=$3
  b=$(ssh $J $C "$CNT")
  for h in $C $S; do ssh $J $h "cd /root/rq; (LC_ALL=C mpstat -P ALL 1 32 > r28_${name}_mpstat.txt 2>&1 < /dev/null &)"; done
  ssh $J $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t 30 $A" > raw28/iperf_$name.txt 2>&1
  sleep 3
  a=$(ssh $J $C "$CNT")
  rx=$(grep receiver raw28/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
  rt=$(grep sender raw28/iperf_$name.txt | tail -1 | awk '{print $(NF-1)}')
  idle=$(for h in $C $S; do ssh $J $h "awk '/^Average/ && \$2 ~ /^[0-9]+\$/ {printf \"%.0f \", \$NF}' /root/rq/r28_${name}_mpstat.txt"; echo -n "/ "; done)
  sh=$(echo "$b | $a" | awk -v d="$A" '{split($0,x,"|"); split(x[1],B," "); split(x[2],E," ");
    o=(d=="-R")?2:1; t=0; for(i=0;i<3;i++){v[i]=E[i*2+o]-B[i*2+o]; t+=v[i]} if(t==0)t=1;
    printf "%.0f/%.0f/%.0f", 100*v[0]/t, 100*v[1]/t, 100*v[2]/t}')
  echo "  $name recv $rx | retr $rt | share $sh | idle c/s $idle"; sleep 4; }

prof() { local name=$1 A=$2 mode=$3
  for h in $C $S; do ssh $J $h "cd /root/rq; p=\$(pgrep -P \$(cat *_P0.pid | head -1)); rm -f perf28_${name}.data
    if [ $mode = proc ]; then tgt=\"-p \$p\"; else tgt=-a; fi
    (sleep 5; setsid timeout 25 perf record -F 999 -g \$tgt -o /root/rq/perf28_${name}.data -- sleep 20 > /dev/null 2>&1 < /dev/null) > /dev/null 2>&1 &"; done
  ssh $J $C "ip netns exec ue iperf3 -c 10.90.0.10 -P 1 -t 30 $A" > raw28/iperf_$name.txt 2>&1
  rx=$(grep receiver raw28/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
  echo "  $name recv $rx"; sleep 6; }
report() { for h in $C $S; do ssh $J $h 'cd /root/rq; for f in perf28_*.data; do b=${f%.data}
    perf report -i $f --stdio --no-children --sort dso,symbol --percent-limit 0.7 2>/dev/null | grep -E "^ +[0-9]" > ${b}_self.txt
    perf report -i $f --stdio --children --sort symbol --percent-limit 3 -g none 2>/dev/null | grep -E "^ +[0-9]" > ${b}_children.txt
    perf report -i $f --stdio --no-children --sort cpu --percent-limit 0.5 2>/dev/null | grep -E "^ +[0-9]" > ${b}_cpu.txt
    perf report -i $f --stdio --no-children --sort comm --percent-limit 1 2>/dev/null | grep -E "^ +[0-9]" > ${b}_comm.txt; done'
    mkdir -p raw28/${h##*.}; scp -q $J "$h:/root/rq/perf28_*.txt" raw28/${h##*.}/; done; }

echo "== start $(date +%T)"; setrps e; route 1; start prof 1 "0" static.spd1
prof proc_up "" proc; prof proc_dn "-R" proc
prof sys_up "" sys;  prof sys_dn "-R" sys
report
echo "done $(date +%T)"
