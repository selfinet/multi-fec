#!/bin/bash
# run38: speed.2 도 같은 1초 계측 (2026-11-20 사용자 "speed.2도 테스트해줘"). run37 하네스 + 변형 교대:
#   v145i(1.4.5 계측) · spd2i(1.4.5-speed.2 계측, GSO·GRO 기본 켬) · spd2nogso(spd2i + MF_UDP_GSO=0), 순서 ×2. speed.2 는 와이어 비호환이라 client·server 같은 바이너리.
# ⚠️ netem 은 egress(run36 조건) — run29/31 에서 egress netem × GSO 하향 저하가 있었다(IFB 에선 재현 안 됨).
# 바이너리: 1.4.5 + 1초 카운터 출력만 추가한 계측 빌드(bin37/mf145i, diff 동봉 — 배포 금지). 조건 run36 과 같음(P0 터널 1, aggregate, 30/54 ms, rps 0, 고정 없음).
# 1초 기록: mf [stat1s](client eagain/over/stale/flushed/senderr/q, server enq/full/stale/flushed/senderr/q) · /proc/net/snmp Udp Rcvbuf/Sndbuf 오류 · iperf3 초당 재전송(송신측).
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw38
restore() { echo "== restore $(date +%T)"
  for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null; pkill -x iperf3; pkill -f '^bash /root/rq/udpsamp38' ; echo 0 > /sys/class/net/lo/queues/rx-0/rps_cpus; sleep 1
    echo \"\$(hostname) rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) mf=\$(pgrep -fc '^./mf38') iperf=\$(pgrep -xc iperf3) samp=\$(pgrep -fc '^bash /root/rq/udpsamp38')\""; done; }
trap restore EXIT
echo "== setup $(date +%T)"
for h in $C $S; do
  scp -q $J bin37/mf145i $h:/root/rq/mf38.v145i; scp -q $J bin37/mfspd2i $h:/root/rq/mf38.spd2i
  ssh $J $h 'cd /root/rq; for f in *.pid; do kill $(cat $f) 2>/dev/null; done; pkill -x iperf3; sleep 1; tc qdisc del dev rq-wg root 2>/dev/null
    echo 0 > /sys/class/net/lo/queues/rx-0/rps_cpus
    printf "%s\n" "while :; do echo \"\$(date +%s%3N) \$(awk '"'"'/^Udp:/{getline; print \$6, \$7}'"'"' /proc/net/snmp)\"; sleep 1; done" > udpsamp38
    for v in v145i spd2i; do echo "$(hostname) $v $(sha256sum mf38.$v | cut -c1-8) $(./mf38.$v --version | sed -n 1p)"; done'; done
ssh $J $S 'cd /root/rq; (setsid timeout 3600 iperf3 -s -B 10.89.0.1 -p 5201 > iperf_s38.log 2>&1 < /dev/null &)'
start() { local v=$1 bin=$2 env=$3
  for pair in "$S server" "$C client"; do set -- $pair
    ssh $J $1 "cd /root/rq; kill \$(cat ${2}_P0.pid) 2>/dev/null; sleep 1
      env $env setsid timeout 1200 ./mf38.$bin --config /root/rq/${2}_P0.conf > ${2}_r38_$v.log 2>&1 < /dev/null & echo \$! > ${2}_P0.pid"; done
  sleep 8
  for h in $S $C; do ssh $J $h "p=\$(pgrep -P \$(cat /root/rq/*_P0.pid | head -1)); echo \"  \$(hostname) running \$(/proc/\$p/exe --version | head -1) env=\$(tr '\\0' '\\n' < /proc/\$p/environ | grep -c MF_UDP_GSO=0)\""; done
  ssh $J $C "ping -c 3 -i 0.3 -q 10.89.0.1 | tail -1"; }
run() { local name=$1 A=$2
  for h in $C $S; do ssh $J $h "cd /root/rq; (setsid timeout 45 bash /root/rq/udpsamp38 > r38_${name}_udp.txt 2>&1 < /dev/null &)"; done
  echo "  $name start $(date +%s%3N)"
  ssh $J $C "iperf3 -c 10.89.0.1 -p 5201 -i 1 --get-server-output $A" > raw38/iperf_$name.txt 2>&1
  echo "  $name end   $(date +%s%3N) $(grep -E 'SUM.*receiver|receiver' raw38/iperf_$name.txt | tail -1 | grep -oE '[0-9.]+ Mbits/sec')"; sleep 6; }
variant() { local v=$1 bin=$2 env=$3; echo "== $v ($bin $env) $(date +%T)"; start $v $bin "$env"
  run ${v}_p8_up "-P 8 -t 30"; run ${v}_p8_dn "-P 8 -t 30 -R"; run ${v}_p1_up "-P 1 -t 30"; run ${v}_p1_dn "-P 1 -t 30 -R"; }
for r in 1 2; do variant v145i_$r v145i ""; variant spd2i_$r spd2i ""; variant spd2nogso_$r spd2i "MF_UDP_GSO=0"; done
for h in $C $S; do ssh $J $h "cd /root/rq; kill \$(cat *_P0.pid) 2>/dev/null"; mkdir -p raw38/${h##*.}; scp -q $J "$h:/root/rq/*_r38_*.log" "$h:/root/rq/r38_*" raw38/${h##*.}/ 2>/dev/null; done
echo "done $(date +%T)"
