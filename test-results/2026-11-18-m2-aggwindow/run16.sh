#!/bin/bash
# RS addmul1 SSSE3 (tools/bench/fec_simd.cpp 를 1.4.4 lib/fec.cpp 에 이식) A/B — 같은 바이너리, MF_NO_SIMD=1 이면 기존 스칼라 경로.
# 조건 = run13/14 base: P0 터널 1개, aggregate, enp4s0 30 ms + enp1s0 54 ms, 손실 0.
# 변형마다: TCP -P 8 상·하향 30 s, UDP 200 Mbps 상·하향 20 s (수신 상한). 순서 스칼라·SIMD·스칼라·SIMD.
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
BIN=/tmp/claude-1000/-home-stevekim-multi-fec/e0768082-ad60-4361-88b8-c886cc679895/scratchpad/wt-simd/multi-fec-static
cd "$(dirname "$0")"; mkdir -p raw16
echo "== setup $(date +%T)"
for h in $C $S; do scp -q $J $BIN $h:/root/rq/multi-fec-static.simd
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    md5sum multi-fec-static.simd | cut -c1-12'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s16.log 2>&1 < /dev/null &)'

start() { local v=$1 envp=$2
  for pair in "$S server" "$C client"; do set -- $pair
    ssh $J $1 "cd /root/rq; kill \$(cat ${2}_P0.pid) 2>/dev/null; sleep 1
      $envp setsid timeout 1200 ./multi-fec-static.simd --config /root/rq/${2}_P0.conf > ${2}_r16_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
  sleep 8; ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1"; }
run() { local name=$1 A=$2 perf=$3
  for h in $C $S; do n=${h##*.}; ssh $J $h "cd /root/rq; nstat -n; p=\$(cat *_P0.pid | head -1); mf=\$(pgrep -P \$p -x multi-fec-stati || echo \$p)
      LC_ALL=C setsid timeout 33 pidstat -h -u -p \$mf 1 > r16_${name}_pid.txt 2>&1 < /dev/null &
      ${perf:+[ $n = 92 ] && setsid timeout 22 perf record -F 999 -p \$mf -o /root/rq/perf16_${name}.data > /dev/null 2>&1 < /dev/null &}
      true"; done
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 $A" > raw16/iperf_$name.txt 2>&1
  sleep 3
  ub=$(for h in $C $S; do ssh $J $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  cpu=$(for h in $C $S; do ssh $J $h "awk '\$NF ~ /multi-fec/ && \$(NF-2) > 5 {s+=\$(NF-2); n++} END{printf \"%.0f\", n?s/n:0}' /root/rq/r16_${name}_pid.txt"; echo -n "/"; done)
  if [[ "$A" == *-u* ]]; then
    rx=$(grep -E "receiver" raw16/iperf_$name.txt | tail -1 | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    ls=$(grep -E "receiver" raw16/iperf_$name.txt | tail -1 | grep -oE '\([0-9.e+-]+%\)')
    echo "  $name recv $rx loss $ls | mfCPU c/s $cpu | rcvbufErr c/s $ub"
  else
    rx=$(grep -E "SUM.*receiver" raw16/iperf_$name.txt | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/) print $(i-1), $i}')
    rt=$(grep -E "SUM.*sender" raw16/iperf_$name.txt | awk '{print $(NF-1)}')
    echo "  $name recv $rx | retr $rt | mfCPU c/s $cpu | rcvbufErr c/s $ub"
  fi; sleep 4; }
variant() { local v=$1 envp=$2 perf=$3; echo "== $v ($envp) $(date +%T)"; start $v "$envp"
  run ${v}_tcp_up   "-P 8 -t 30" $perf
  run ${v}_tcp_down "-P 8 -t 30 -R"
  run ${v}_udp_up   "-u -b 200M -l 1200 -t 20"
  run ${v}_udp_down "-u -b 200M -l 1200 -t 20 -R"
  ssh $J $C "echo \"  client EAGAIN=\$(grep -c EAGAIN /root/rq/client_r16_$v.log) \$(grep 'pending queue full' /root/rq/client_r16_$v.log | tail -1 | grep -oE 'total [0-9]+')\""; }

variant scalar1 "MF_NO_SIMD=1" 1
variant simd1   ""             1
variant scalar2 "MF_NO_SIMD=1"
variant simd2   ""
for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null"; mkdir -p raw16/${h##*.}; scp -q $J "$h:/root/rq/*_r16_*" "$h:/root/rq/r16_*" raw16/${h##*.}/ 2>/dev/null; done
ssh $J $C 'cd /root/rq; for f in perf16_*.data; do perf report -i $f --stdio --sort symbol 2>/dev/null | grep -E "^ +[0-9]" | head -8 > ${f%.data}.txt; done'
scp -q $J "$C:/root/rq/perf16_*.txt" raw16/ 2>/dev/null
echo "done $(date +%T)"
