#!/bin/bash
# run61 — 손실 1 % 를 egress netem 으로(IFB 없음). run59 의 "수신 GRO 뒤 IFB 묶음 손실"을 피한 조건에서 다시 본다.
#   egress netem 도 송신 GSO 묶음(UDP_SEGMENT)을 qdisc 에서 통째로 받는다(분할은 qdisc 뒤) → 송신 GSO 를 끈 변형이 "회선 손실 = 패킷 단위"에 해당.
#   E11 = 기본(GSO·GRO 켬) · E01 = MF_UDP_GSO=0(GRO 켬) · E00 = MF_UDP_GSO=0 MF_UDP_GRO=0. 모두 client·server 둘 다.
#   mt.2 10b361ea, --workers 3 --worker-cpus 0,1,2, rps 8, 터널 1개, egress netem 30/54 ms(enp4s0 1:1·1:2) + 54 ms(enp1s0).
#   손실 0 % E11·E01 ×1 → 손실 1 % E11·E01·E00 ×2 교대. egress netem 의 버림 수 ÷ 통과 패킷(세그먼트)으로 묶음 손실 여부를 직접 확인.
# 2026-11-23 사용자 "egress netem으로 손실 1% 재시험 진행해줘".
RUN=r61; RAW=raw61
cd "$(dirname "$0")"; . ./lib.sh
echo "== setup $(date +%T)"
bins
[ "${DRY:-0}" = 1 ] && { echo "DRY=1 — 여기서 끝(상태 변경 없음)"; trap - EXIT; exit 0; }

for h in $C $S; do rsh $h "cd /root/rq; for f in *.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; sleep 1; $CAKE_OFF"; done
rsh $S "cd /root/rq; (setsid timeout 7200 ip netns exec hq iperf3 -s > iperf_hq_${RUN}.log 2>&1 < /dev/null &)"
# IFB 없이 egress 그대로. 끝나면(실패 포함) restore2 가 IFB 정리 + egress netem 기준 복원·대조를 한다.
rsh $C 'echo 1 > /root/rq/r30_dst'; rsh $S 'echo 2 > /root/rq/r30_dst'
for h in $C $S; do rsh $h 'tc qdisc show dev enp4s0 > /root/rq/r30_tc_before.txt; tc qdisc show dev enp1s0 >> /root/rq/r30_tc_before.txt; tc filter show dev enp4s0 | grep -E "match|flowid" >> /root/rq/r30_tc_before.txt; echo "$MFROLE egress 기준 저장 $(grep -c netem /root/rq/r30_tc_before.txt) netem, ifb $(ip -br link show type ifb | wc -l)"'; done
trap restore2 EXIT
echo "-- 하부 ping (기대 RTT 60 / 108 ms)"
rsh $C 'for a in 172.31.10.1 172.31.11.1 172.31.20.1; do echo "$a $(ping -c 5 -i 0.2 -q $a | tail -1)"; done'

esetnet() { local x=$1 h
  for h in $C $S; do rsh $h "tc qdisc change dev enp4s0 parent 1:1 handle 10: netem limit 20000 delay 30ms loss $x%; tc qdisc change dev enp4s0 parent 1:2 handle 20: netem limit 20000 delay 54ms loss $x%; tc qdisc change dev enp1s0 root handle 8003: netem limit 20000 delay 54ms loss $x%; echo \"  \$MFROLE \$(tc qdisc show dev enp4s0 | grep -o 'netem [0-9]*:.*' | paste -sd' ') | \$(tc qdisc show dev enp1s0 | grep -o 'netem [0-9]*:.*')\""; done; }
# run() 의 큐 열(A100/B50 이름은 lib 그대로): A = enp4s0 1:1(30 ms), B = enp1s0 root(54 ms) — 송신측 egress
QS='for s in "enp4s0 parent 1:1" "enp1s0 root"; do tc -s qdisc show dev $s | awk "/Sent/{b=\$2; for(i=1;i<=NF;i++) if(\$i==\"(dropped\") {x=\$(i+1); sub(\",\",\"\",x)}} END{printf \"%s %s \", b, x}"; done'
# egress netem 3개 합계: 바이트 · 패킷(세그먼트 단위로 셈) · 버림(skb 단위로 셈)
ESZ='tc -s qdisc show dev enp4s0 | awk "/^qdisc netem/{f=1; next} /^qdisc/{f=0} f && /Sent/{b+=\$2; p+=\$4; x=\$7; sub(\",\",\"\",x); d+=x; f=0} END{printf \"%d %d %d \", b, p, d}"
  tc -s qdisc show dev enp1s0 | awk "/^qdisc netem/{f=1; next} /^qdisc/{f=0} f && /Sent/{b+=\$2; p+=\$4; x=\$7; sub(\",\",\"\",x); d+=x; f=0} END{printf \"%d %d %d\", b, p, d}"'
esnap() { local h; for h in $C $S; do rsh $h "$ESZ"; echo -n " "; done; }

start() { local v=$1 kind=$2 EV pair; stopall; setrps 8; route 1
  case $kind in E11) EV="";; E01) EV="MF_UDP_GSO=0";; E00) EV="MF_UDP_GSO=0 MF_UDP_GRO=0";; esac
  for pair in "$S server" "$C client"; do set -- $pair
    rsh $1 "cd /root/rq; $EV setsid timeout 1500 ./mmulti-fec-dist --config /root/rq/${2}_P0.conf --workers 3 --worker-cpus 0,1,2 > ${2}_MT_${RUN}_$v.log 2>&1 < /dev/null & echo \$! > ${2}_MT.pid"; done
  sleep 10
  rsh $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; echo \"  route \$(ip route show 10.90.0.0/24 | wc -l) rps \$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) procs \$(pgrep -c mmulti-fec-dist)\""
  for pair in "$C client" "$S server"; do set -- $pair
    rsh $1 "cd /root/rq; echo \"  \$MFROLE env GSO=0:\$(grep -ac MF_UDP_GSO=0 /proc/\$(cat ${2}_MT.pid)/environ) GRO=0:\$(grep -ac MF_UDP_GRO=0 /proc/\$(cat ${2}_MT.pid)/environ)\""; done; }
variant() { local v=$1 kind=$2 s0 s1
  echo "== $v ($kind) $(date +%T)"; start $v $kind
  s0=$(esnap)
  run ${v}_p1_up 1 ""; run ${v}_p1_dn 1 "-R"; run ${v}_p8_up 8 ""; run ${v}_p8_dn 8 "-R"
  s1=$(esnap)
  echo $s0 $s1 | awk '{cb=$7-$1; cp=$8-$2; cd=$9-$3; cb2=$10-$4; cp2=$11-$5; cd2=$12-$6; sb=$19-$13; sp=$20-$14; sd=$21-$15; sb2=$22-$16; sp2=$23-$17; sd2=$24-$18
    P=cp+cp2; D=cd+cd2; Q=sp+sp2; E=sd+sd2
    printf "  egress netem  client 패킷 %d 버림 %d (%.2f %%)  server 패킷 %d 버림 %d (%.2f %%)  평균 B/pkt %.0f / %.0f\n", P, D, P?100*D/P:0, Q, E, Q?100*E/Q:0, P?(cb+cb2)/P:0, Q?(sb+sb2)/Q:0}'
  logsum $v
  rsh $C "cd /root/rq; grep -ah 'batch gso' client_MT_${RUN}_$v.log | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c22-"; }

esetnet 0
variant l0_E11 E11; variant l0_E01 E01
esetnet 1
for r in 1 2; do variant l1_E11_$r E11; variant l1_E01_$r E01; variant l1_E00_$r E00; done
esetnet 0
stopall
rget
echo "done $(date +%T)"
