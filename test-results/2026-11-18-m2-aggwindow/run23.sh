#!/bin/bash
# --pin-cpu 옵션 확인 — 바이너리 .pin(perf/j1900-cpu 7584b2a + --pin-cpu, 미커밋), 조건 run16~19 와 같음(P0, aggregate, 30/54 ms, 손실 0).
# 변형: rps0(끔) · eopt(rps e + --pin-cpu 0) · etask(rps e + taskset -c 0). .92·.93 양쪽 같은 값. 순서 ×3.
# 런타임 sysfs 만 바꾸고, 끝나면(어떤 종료든) 0 으로 복원한다.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw23
BIN=/tmp/claude-1000/-home-stevekim-multi-fec/e0768082-ad60-4361-88b8-c886cc679895/scratchpad/multi-fec-static.pin
setrps() { for h in $C $S; do ssh $J $h "echo $1 > /sys/class/net/lo/queues/rx-0/rps_cpus; echo \"\$(hostname) lo rps_cpus=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus)\""; done; }
restore() { echo "== restore $(date +%T)"; setrps 0; for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null; true"; done; }
trap restore EXIT
drops() { ssh $J $1 "awk '{s+=strtonum(\"0x\"\$2)} END{print s}' /proc/net/softnet_stat"; }
echo "== setup $(date +%T)"
for h in $C $S; do scp -q $J $BIN $h:/root/rq/multi-fec-static.pin; ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null; md5sum multi-fec-static.pin | cut -c1-12'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s23.log 2>&1 < /dev/null &)'
start() { local v=$1 pin=$2 extra=$3
  for pair in "$S server" "$C client"; do set -- $pair
    ssh $J $1 "cd /root/rq; kill \$(cat ${2}_P0.pid) 2>/dev/null; sleep 1
      $pin setsid timeout 1200 ./multi-fec-static.pin --config /root/rq/${2}_P0.conf $extra > ${2}_r23_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
  sleep 8; ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1; mf=\$(pgrep -P \$(cat /root/rq/client_P0.pid) -x multi-fec-stati); taskset -pc \$mf; grep -ho 'pinned to CPU.*' /root/rq/client_r23_$v.log | head -1"; }
run() { local name=$1 A=$2
  d0c=$(drops $C); d0s=$(drops $S)
  for h in $C $S; do ssh $J $h "cd /root/rq; nstat -n; p=\$(cat *_P0.pid | head -1); mf=\$(pgrep -P \$p -x multi-fec-stati || echo \$p)
      LC_ALL=C setsid timeout 33 pidstat -h -u -p \$mf 1 > r23_${name}_pid.txt 2>&1 < /dev/null &
      LC_ALL=C setsid timeout 33 mpstat -P ALL 1 30 > r23_${name}_mp.txt 2>&1 < /dev/null &
      true"; done
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 $A" > raw23/iperf_$name.txt 2>&1
  sleep 3
  dd="$(( $(drops $C) - d0c ))/$(( $(drops $S) - d0s ))"
  ub=$(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  cpu=$(for h in $C $S; do ssh $J $h "awk '\$NF ~ /multi-fec/ && \$(NF-2) > 5 {s+=\$(NF-2); n++} END{printf \"%.0f\", n?s/n:0}' /root/rq/r23_${name}_pid.txt"; echo -n "/"; done)
  if [[ "$A" == *-u* ]]; then
    rx=$(grep -E "receiver" raw23/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    ls=$(grep -E "receiver" raw23/iperf_$name.txt | tail -1 | grep -oE '\([0-9.e+-]+%\)')
    echo "  $name recv $rx loss $ls | mfCPU c/s $cpu | rcvbufErr c/s $ub | softnetDrop c/s $dd"
  else
    rx=$(grep -E "SUM.*receiver" raw23/iperf_$name.txt | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    rt=$(grep -E "SUM.*sender" raw23/iperf_$name.txt | awk '{print $(NF-1)}')
    echo "  $name recv $rx | retr $rt | mfCPU c/s $cpu | rcvbufErr c/s $ub | softnetDrop c/s $dd"
  fi; sleep 4; }
variant() { local v=$1 mask=$2 pin=$3 extra=$4; echo "== $v (rps=$mask ${pin:-no-taskset} $extra) $(date +%T)"; setrps $mask; start $v "$pin" "$extra"
  run ${v}_tcp_up   "-P 8 -t 30"
  run ${v}_tcp_down "-P 8 -t 30 -R"
  run ${v}_udp_up   "-u -b 200M -l 1200 -t 20"
  run ${v}_udp_down "-u -b 200M -l 1200 -t 20 -R"
  ssh $J $C "echo \"  client EAGAIN=\$(grep -c EAGAIN /root/rq/client_r23_$v.log) \$(grep 'pending queue full' /root/rq/client_r23_$v.log | tail -1 | grep -oE 'total [0-9]+')\""; }
variant rps0_1 0
variant eopt_1 e "" "--pin-cpu 0"
variant etask_1 e "taskset -c 0"
variant rps0_2 0
variant eopt_2 e "" "--pin-cpu 0"
variant etask_2 e "taskset -c 0"
variant rps0_3 0
variant eopt_3 e "" "--pin-cpu 0"
variant etask_3 e "taskset -c 0"
for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null"; mkdir -p raw23/${h##*.}; scp -q $J "$h:/root/rq/*_r23_*" "$h:/root/rq/r23_*" raw23/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
