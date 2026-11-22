#!/bin/bash
# 속도 특별 버전 ② WG 쪽 sendmmsg 묶음 A/B — v145(1.4.5 dist) vs spd(1.4.5-speed.1 = wg_batch, dist).
# 조건 run16~23 과 같음: P0 터널 1개, aggregate, 30/54 ms, 손실 0. RPS 0(고정 없음) / RPS e + --pin-cpu 0. 순서 ×2.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
BIN=/home/stevekim/mf-speed/multi-fec-dist
cd "$(dirname "$0")"; mkdir -p raw25
echo "== setup $(date +%T)"
for h in $C $S; do scp -q $J $BIN $h:/root/rq/multi-fec-dist.spd1
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    md5sum multi-fec-dist.v145 multi-fec-dist.spd1 | cut -c1-12 | paste -sd" "'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s16.log 2>&1 < /dev/null &)'

start() { local v=$1 bin=$2 pin=$3
  for pair in "$S server" "$C client"; do set -- $pair
    ssh $J $1 "cd /root/rq; kill \$(cat ${2}_P0.pid) 2>/dev/null; sleep 1
      setsid timeout 1200 ./multi-fec-dist.$bin --config /root/rq/${2}_P0.conf $pin > ${2}_r25_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
  sleep 8; ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1"; }
run() { local name=$1 A=$2 perf=$3
  for h in $C $S; do n=${h##*.}; ssh $J $h "cd /root/rq; nstat -n; p=\$(cat *_P0.pid | head -1); mf=\$(pgrep -P \$p || echo \$p)
      LC_ALL=C setsid timeout 33 pidstat -h -u -p \$mf 1 > r25_${name}_pid.txt 2>&1 < /dev/null &
      ${perf:+[ $n = 92 ] && setsid timeout 22 perf record -F 999 -p \$mf -o /root/rq/perf25_${name}.data > /dev/null 2>&1 < /dev/null &}
      true"; done
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 $A" > raw25/iperf_$name.txt 2>&1
  sleep 3
  ub=$(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  cpu=$(for h in $C $S; do ssh $J $h "awk '\$NF ~ /multi-fec/ && \$(NF-2) > 5 {s+=\$(NF-2); n++} END{printf \"%.0f\", n?s/n:0}' /root/rq/r25_${name}_pid.txt"; echo -n "/"; done)
  if [[ "$A" == *-u* ]]; then
    rx=$(grep -E "receiver" raw25/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    ls=$(grep -E "receiver" raw25/iperf_$name.txt | tail -1 | grep -oE '\([0-9.e+-]+%\)')
    echo "  $name recv $rx loss $ls | mfCPU c/s $cpu | rcvbufErr c/s $ub"
  else
    rx=$(grep -E "SUM.*receiver" raw25/iperf_$name.txt | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    rt=$(grep -E "SUM.*sender" raw25/iperf_$name.txt | awk '{print $(NF-1)}')
    echo "  $name recv $rx | retr $rt | mfCPU c/s $cpu | rcvbufErr c/s $ub"
  fi; sleep 4; }
setrps() { for h in $C $S; do ssh $J $h "echo $1 > /sys/class/net/lo/queues/rx-0/rps_cpus"; done; }
restore() { echo "== restore $(date +%T)"; setrps 0; for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null; pkill -x iperf3; true; echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) mf=\$(pgrep -c multi-fec)\""; done; }
trap restore EXIT
variant() { local v=$1 bin=$2 mask=$3 pin=$4; echo "== $v ($bin rps=$mask $pin) $(date +%T)"; setrps $mask; start $v $bin "$pin"
  run ${v}_tcp_up   "-P 8 -t 30"
  run ${v}_tcp_down "-P 8 -t 30 -R"
  run ${v}_udp_up   "-u -b 200M -l 1200 -t 20"
  run ${v}_udp_down "-u -b 200M -l 1200 -t 20 -R"
  ssh $J $C "echo \"  client EAGAIN=\$(grep -c EAGAIN /root/rq/client_r25_$v.log) wg_batch_err=\$(grep -c wg_batch /root/rq/client_r25_$v.log)\""; ssh $J $S "echo \"  server wg_batch_err=\$(grep -c wg_batch /root/rq/server_r25_$v.log)\""; }

for r in 1 2; do
  variant v145_r0_$r  v145 0 ""
  variant spd_r0_$r   spd1 0 ""
  variant v145_e_$r   v145 e "--pin-cpu 0"
  variant spd_e_$r    spd1 e "--pin-cpu 0"
done
for h in $C $S; do mkdir -p raw25/${h##*.}; scp -q $J "$h:/root/rq/*_r25_*" "$h:/root/rq/r25_*" raw25/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
