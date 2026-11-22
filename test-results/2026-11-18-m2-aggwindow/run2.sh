#!/bin/bash
# A/B: 1.4.4 vs fix/agg-pacing (headroom 125 / 200). 같은 구성(run1.sh 참고)
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw2
restart() { # $1 bin suffix  $2 headroom(env, empty=none)  $3 tag
  for pair in "$S server" "$C client"; do set -- $1 "$2" $3 $pair; h=$4; role=$5
    ssh $J $h "cd /root/rq; [ -f $role.pid ] && kill \$(cat $role.pid) 2>/dev/null; sleep 1
      ${2:+MF_PACE_HEADROOM=$2} setsid timeout 3600 ./multi-fec-dist.$1 --config /root/rq/$role.conf > ${role}_$3.log 2>&1 < /dev/null & echo \$! > $role.pid"
  done
  sleep 8
  ssh $J $C "ping -c 5 -i 0.3 -q 10.89.0.1 | tail -1"
}
mon() { for h in $C $S; do n=${h##*.}
    ssh $J $h "cd /root/rq; p=\$(cat client.pid server.pid 2>/dev/null | head -1); mf=\$(pgrep -P \$p multi-fec-dist || echo \$p);
      LC_ALL=C setsid timeout $(( $2 + 3 )) pidstat -h -u -p \$mf 1 > m2_$1_pid_$n.txt 2>&1 < /dev/null &
      LC_ALL=C setsid timeout $(( $2 + 3 )) mpstat -P ALL 1 > m2_$1_cpu_$n.txt 2>&1 < /dev/null &"; done; }
run() { echo "== $1 $(date +%T)"; mon $1 $3
  ssh $J $C "iperf3 -c 10.89.0.1 -P 8 -t $3 -i 1 $4" > raw2/iperf_$1.txt 2>&1
  grep -E "SUM.*receiver" raw2/iperf_$1.txt; sleep 5; }
for v in "v144::A" "pace::B125" "pace:200:C200"; do
  IFS=: read b hr tag <<< "$v"
  echo "#### $tag ($b headroom=${hr:-default})"; restart $b "$hr" $tag
  run ${tag}_up 10.89.0.1 60 ""
  run ${tag}_down 10.89.0.1 60 "-R"
done
for h in $C $S; do scp -q $J "$h:/root/rq/m2_*" raw2/; scp -q $J "$h:/root/rq/*_A.log" "$h:/root/rq/*_B125.log" "$h:/root/rq/*_C200.log" raw2/ 2>/dev/null; done
echo done
