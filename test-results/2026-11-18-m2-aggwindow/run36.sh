#!/bin/bash
# 1.4.4 vs 1.4.5 태그 dist 같은 세션 교대 (2026-11-20 사용자 "1.4.4와 1.4.5의 성능 비교해줘").
# 조건 run23 과 같음(P0 터널 1개, aggregate, 30/54 ms egress netem, 손실 0). rps 0·코어 고정 없음 = 바이너리만 교체.
# 변형: v144(dist 3baba552) · v145(dist b91ea178), 순서 v144→v145 ×3. 끝나면(어떤 종료든) mf 종료·rps 0 확인.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw36
D=$HOME/multi-fec/dist
restore() { echo "== restore $(date +%T)"
  for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null; pkill -x iperf3; echo 0 > /sys/class/net/lo/queues/rx-0/rps_cpus; sleep 1
    echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) mf=\$(pgrep -fc '^./mf36') iperf=\$(pgrep -xc iperf3)\""; done; }
trap restore EXIT
drops() { ssh $J $1 "awk '{s+=strtonum(\"0x\"\$2)} END{print s}' /proc/net/softnet_stat"; }
echo "== setup $(date +%T)"
for h in $C $S; do
  scp -q $J $D/multi-fec-dist-v1.4.4 $h:/root/rq/mf36.v144; scp -q $J $D/multi-fec-dist-v1.4.5 $h:/root/rq/mf36.v145
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    echo 0 > /sys/class/net/lo/queues/rx-0/rps_cpus
    for v in v144 v145; do echo "$(hostname) $v $(sha256sum mf36.$v | cut -c1-8) $(./mf36.$v --version | head -1)"; done'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s36.log 2>&1 < /dev/null &)'
start() { local v=$1 bin=$2
  for pair in "$S server" "$C client"; do set -- $pair
    ssh $J $1 "cd /root/rq; kill \$(cat ${2}_P0.pid) 2>/dev/null; sleep 1
      setsid timeout 1200 ./mf36.$bin --config /root/rq/${2}_P0.conf > ${2}_r36_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
  sleep 8
  for h in $S $C; do ssh $J $h "p=\$(pgrep -P \$(cat /root/rq/*_P0.pid | head -1)); echo \"  \$(hostname) running \$(/proc/\$p/exe --version | head -1)\""; done
  ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1"; }
run() { local name=$1 A=$2
  d0c=$(drops $C); d0s=$(drops $S)
  for h in $C $S; do ssh $J $h "cd /root/rq; nstat -n; mf=\$(pgrep -P \$(cat *_P0.pid | head -1))
      LC_ALL=C setsid timeout 33 pidstat -h -u -p \$mf 1 > r36_${name}_pid.txt 2>&1 < /dev/null &
      true"; done
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 $A" > raw36/iperf_$name.txt 2>&1
  sleep 3
  dd="$(( $(drops $C) - d0c ))/$(( $(drops $S) - d0s ))"
  ub=$(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  cpu=$(for h in $C $S; do ssh $J $h "awk '\$NF ~ /mf36/ && \$(NF-2) > 5 {s+=\$(NF-2); n++} END{printf \"%.0f\", n?s/n:0}' /root/rq/r36_${name}_pid.txt"; echo -n "/"; done)
  if [[ "$A" == *-u* ]]; then
    rx=$(grep -E "receiver" raw36/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    ls=$(grep -E "receiver" raw36/iperf_$name.txt | tail -1 | grep -oE '\([0-9.e+-]+%\)')
    echo "  $name recv $rx loss $ls | mfCPU c/s $cpu | rcvbufErr c/s $ub | softnetDrop c/s $dd"
  else
    rx=$(grep -E "SUM.*receiver" raw36/iperf_$name.txt | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    rt=$(grep -E "SUM.*sender" raw36/iperf_$name.txt | awk '{print $(NF-1)}')
    echo "  $name recv $rx | retr $rt | mfCPU c/s $cpu | rcvbufErr c/s $ub | softnetDrop c/s $dd"
  fi; sleep 4; }
variant() { local v=$1 bin=$2; echo "== $v ($bin, rps 0, no pin) $(date +%T)"; start $v $bin
  run ${v}_tcp_up   "-P 8 -t 30"
  run ${v}_tcp_down "-P 8 -t 30 -R"
  run ${v}_udp_up   "-u -b 200M -l 1200 -t 20"
  run ${v}_udp_down "-u -b 200M -l 1200 -t 20 -R"
  ssh $J $C "echo \"  client EAGAIN=\$(grep -c EAGAIN /root/rq/client_r36_$v.log) \$(grep 'pending queue full' /root/rq/client_r36_$v.log | tail -1 | grep -oE 'total [0-9]+')\""; }
for r in 1 2 3; do variant v144_$r v144; variant v145_$r v145; done
for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null"; mkdir -p raw36/${h##*.}; scp -q $J "$h:/root/rq/*_r36_*" "$h:/root/rq/r36_*" raw36/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
