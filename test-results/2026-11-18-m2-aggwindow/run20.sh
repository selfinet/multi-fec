#!/bin/bash
# lo RPS A/B — 바이너리 .lazylog(1.4.4+SSSE3+no-peek+로그 지연평가), 조건 run16~19 와 같음(P0, aggregate, 30/54 ms, 손실 0).
# 변형: rps0(끔) · rpsf(lo rps_cpus=f) · rpse(lo rps_cpus=e + multi-fec taskset -c 0). .92·.93 양쪽 같은 값. 순서 0·f·e·0·f·e.
# 런타임 sysfs 만 바꾸고, 끝나면(어떤 종료든) 0 으로 복원한다.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw20
setrps() { for h in $C $S; do ssh $J $h "echo $1 > /sys/class/net/lo/queues/rx-0/rps_cpus; echo \"\$(hostname) lo rps_cpus=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus)\""; done; }
restore() { echo "== restore $(date +%T)"; setrps 0; for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null; true"; done; }
trap restore EXIT
drops() { ssh $J $1 "awk '{s+=strtonum(\"0x\"\$2)} END{print s}' /proc/net/softnet_stat"; }
echo "== setup $(date +%T)"
for h in $C $S; do ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null; md5sum multi-fec-static.lazylog | cut -c1-12'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3000 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s20.log 2>&1 < /dev/null &)'
start() { local v=$1 pin=$2
  for pair in "$S server" "$C client"; do set -- $pair
    ssh $J $1 "cd /root/rq; kill \$(cat ${2}_P0.pid) 2>/dev/null; sleep 1
      $pin setsid timeout 1200 ./multi-fec-static.lazylog --config /root/rq/${2}_P0.conf > ${2}_r20_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
  sleep 8; ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1; mf=\$(pgrep -P \$(cat /root/rq/client_P0.pid) -x multi-fec-stati); taskset -pc \$mf"; }
run() { local name=$1 A=$2
  d0c=$(drops $C); d0s=$(drops $S)
  for h in $C $S; do ssh $J $h "cd /root/rq; nstat -n; p=\$(cat *_P0.pid | head -1); mf=\$(pgrep -P \$p -x multi-fec-stati || echo \$p)
      LC_ALL=C setsid timeout 33 pidstat -h -u -p \$mf 1 > r20_${name}_pid.txt 2>&1 < /dev/null &
      LC_ALL=C setsid timeout 33 mpstat -P ALL 1 30 > r20_${name}_mp.txt 2>&1 < /dev/null &
      true"; done
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 $A" > raw20/iperf_$name.txt 2>&1
  sleep 3
  dd="$(( $(drops $C) - d0c ))/$(( $(drops $S) - d0s ))"
  ub=$(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  cpu=$(for h in $C $S; do ssh $J $h "awk '\$NF ~ /multi-fec/ && \$(NF-2) > 5 {s+=\$(NF-2); n++} END{printf \"%.0f\", n?s/n:0}' /root/rq/r20_${name}_pid.txt"; echo -n "/"; done)
  if [[ "$A" == *-u* ]]; then
    rx=$(grep -E "receiver" raw20/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    ls=$(grep -E "receiver" raw20/iperf_$name.txt | tail -1 | grep -oE '\([0-9.e+-]+%\)')
    echo "  $name recv $rx loss $ls | mfCPU c/s $cpu | rcvbufErr c/s $ub | softnetDrop c/s $dd"
  else
    rx=$(grep -E "SUM.*receiver" raw20/iperf_$name.txt | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    rt=$(grep -E "SUM.*sender" raw20/iperf_$name.txt | awk '{print $(NF-1)}')
    echo "  $name recv $rx | retr $rt | mfCPU c/s $cpu | rcvbufErr c/s $ub | softnetDrop c/s $dd"
  fi; sleep 4; }
variant() { local v=$1 mask=$2 pin=$3; echo "== $v (rps=$mask ${pin:-no-pin}) $(date +%T)"; setrps $mask; start $v "$pin"
  run ${v}_tcp_up   "-P 8 -t 30"
  run ${v}_tcp_down "-P 8 -t 30 -R"
  run ${v}_udp_up   "-u -b 200M -l 1200 -t 20"
  run ${v}_udp_down "-u -b 200M -l 1200 -t 20 -R"
  ssh $J $C "echo \"  client EAGAIN=\$(grep -c EAGAIN /root/rq/client_r20_$v.log) \$(grep 'pending queue full' /root/rq/client_r20_$v.log | tail -1 | grep -oE 'total [0-9]+')\""; }
variant rps0_1 0
variant rpsf_1 f
variant rpse_1 e "taskset -c 0"
variant rps0_2 0
variant rpsf_2 f
variant rpse_2 e "taskset -c 0"
for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null"; mkdir -p raw20/${h##*.}; scp -q $J "$h:/root/rq/*_r20_*" "$h:/root/rq/r20_*" raw20/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
