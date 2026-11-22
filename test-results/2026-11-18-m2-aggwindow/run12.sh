#!/bin/bash
# run7 과 같은 조건(30/54 ms, 손실 0, 터널마다 iperf3 직접)에서 multi-fec 를 코어 고정: 쌍 k → CPU (k+1) (1,2,3).
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw12
echo "== setup $(date +%T)"
for h in $C $S; do ssh $J $h 'cd /root/rq
  tc qdisc change dev enp4s0 parent 1:1 handle 10: netem delay 30ms limit 20000
  tc qdisc change dev enp4s0 parent 1:2 handle 20: netem delay 54ms limit 20000
  tc qdisc replace dev enp1s0 root netem delay 54ms limit 20000
  for f in *_P?.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1
  echo "$(hostname): $(tc qdisc show | grep -oE "netem [0-9a-f]+: .*delay [0-9.]+ms( loss [0-9]+%)?" | paste -sd" ")"'; done
for pair in "$S server" "$C client"; do set -- $pair; ssh $J $1 "cd /root/rq; for k in 0 1 2; do setsid timeout 3600 taskset -c \$((k+1)) ./multi-fec-static.v144 --config /root/rq/${2}_P\$k.conf > ${2}_P\${k}_r12.log 2>&1 < /dev/null & echo \$! > ${2}_P\$k.pid; done"; done
ssh $J $S 'cd /root/rq; for k in 0 1 2; do (setsid timeout 3600 iperf3 -s -B 10.89.$k.1 -p $((5201+k)) > iperf_s12_$k.log 2>&1 < /dev/null &); done'
sleep 10
for h in $C $S; do ssh $J $h 'cd /root/rq; for f in *_P?.pid; do p=$(pgrep -P $(cat $f) -x multi-fec-stati); echo "$(hostname) $f pid=$p $(taskset -pc $p | sed "s/.*: /cpus=/")"; done'; done
ssh $J $C 'for k in 0 1 2; do echo "pair$k $(ping -c 4 -i 0.3 -q 10.89.$k.1 | tail -1)"; done; echo "path1 $(ping -c 3 -q 172.31.10.1 | tail -1)"; echo "path2 $(ping -c 3 -q 172.31.20.1 | tail -1)"'

MON='cd /root/rq; nstat -n; P=$(for f in *_P?.pid; do pgrep -P $(cat $f) -x multi-fec-stati; done | paste -sd,)
 for f in *_P?.pid; do echo "$f $(pgrep -P $(cat $f) -x multi-fec-stati)"; done > r12_NAME_pidmap.txt
 (mpstat -P ALL 1 32 > r12_NAME_mpstat.txt 2>&1 &); (pidstat -u -p $P 1 32 > r12_NAME_pid.txt 2>&1 &)'
run() { local name=$1 n=$2 A=$3
  echo "== $name $(date +%T)"
  for h in $C $S; do ssh $J $h "${MON//NAME/$name}"; done
  ssh $J $C "cd /root/rq; for k in \$(seq 0 $((n-1))); do iperf3 -c 10.89.\$k.1 -p \$((5201+k)) -P 8 -t 30 $A > r12_${name}_\$k.txt 2>&1 & done; wait"
  sleep 3
  for h in $C $S; do ssh $J $h "cd /root/rq; nstat -z UdpRcvbufErrors UdpInErrors TcpRetransSegs > r12_${name}_nstat.txt; sleep 0"; done
  local tot=0
  for k in $(seq 0 $((n-1))); do
    v=$(ssh $J $C "grep -E 'SUM.*receiver' /root/rq/r12_${name}_$k.txt" | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1)}')
    echo "  pair$k ${v} Mbps"; tot=$(echo "$tot + ${v:-0}" | bc); done
  echo "  TOTAL $tot Mbps"; sleep 5; }

for n in 1 2 3; do for r in up1 down1 up2 down2; do A=""; [[ $r == down* ]] && A="-R"; run n${n}_$r $n "$A"; done; done

for h in $C $S; do mkdir -p raw12/${h##*.}; scp -q $J "$h:/root/rq/r12_*" "$h:/root/rq/*_P?.log" raw12/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
