# lib.sh — J1900 .92(client) ↔ .93(server) 시험 하네스 공용 함수 (2026-11-22, run54.sh 에서 추출)
#
# 쓰는 법 (새 runNN.sh 맨 앞):
#   RUN=r55; RAW=raw55                      # 원격 임시 파일 접두사 · 로컬 원자료 폴더
#   . "$(dirname "$0")/lib.sh"              # 실행 시 lib.sh 해시를 출력한다 — 나중에 어떤 버전이었는지 추적용
#   env_up                                  # IFB netem 적용 + EXIT 때 전부 원복(trap)
#
# 원칙
# - 원격 명령은 rsh 로 보낸다. 출력에 장비 호스트명 대신 $MFROLE(client92/server93)을 쓴다 — 공개 리포에 장비 이름이 남지 않게.
# - .92 는 배포 예정 장비다. 여기 함수는 런타임 상태(tc·rps·라우트·프로세스)만 바꾸고 영구 설정은 건드리지 않는다.
# - run1~54.sh 는 실행 당시 기록이라 이 파일을 쓰지 않는다(옛 점프 주소 10.0.3.3 그대로).
# - 이 파일을 고치면 이후 모든 runNN.sh 에 반영된다. 동작이 바뀌는 수정은 날짜와 함께 아래 변경 기록에 남길 것.
#
# 변경 기록
#   2026-11-22  run54.sh 에서 추출. mini 10.0.5.3, 역할 이름 출력.
#   2026-11-23  TZ=Asia/Seoul — 작업 서버 sv2 가 UTC 라 출력 시각이 J1900(KST)·보고서와 어긋났다. run55 는 이 수정 전(UTC)으로 돌았다.

: "${RUN:?RUN 을 먼저 정할 것 (예: RUN=r55)}" "${RAW:?RAW 를 먼저 정할 것 (예: RAW=raw55)}"
export TZ=Asia/Seoul
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
echo "== lib.sh $(sha256sum "$LIB_DIR/lib.sh" | cut -c1-12)  RUN=$RUN RAW=$RAW"
mkdir -p "$RAW"

# ---- 접속 · 역할 이름 ----
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.5.3'
C=root@192.168.2.92; S=root@192.168.2.93
role() { case "$1" in "$C") echo client92;; "$S") echo server93;; *) echo "${1##*@}";; esac; }
rsh()  { local h=$1; shift; ssh $J "$h" "export MFROLE=$(role "$h");" "$@"; }
rput() { local src=$1 dst=$2; for h in $C $S; do scp -q $J "$src" "$h:$dst"; done; }          # 두 대에 같은 파일 올리기
rget() { for h in $C $S; do mkdir -p "$RAW/${h##*.}"; scp -q $J "$h:/root/rq/${RUN}_*" "$h:/root/rq/*_${RUN}_*" "$RAW/${h##*.}/" 2>/dev/null; done; }

# ---- 런타임 상태 ----
setrps() { for h in $C $S; do rsh $h "echo $1 > /sys/class/net/lo/queues/rx-0/rps_cpus"; done; }
route()  { local n=$1 nh="" k d; for k in $(seq 0 $((n-1))); do d=rq-wg; [ $k -gt 0 ] && d=rq-wg$((k+1)); nh="$nh nexthop dev $d"; done
  rsh $C "ip route replace 10.90.0.0/24 $nh"; rsh $S "ip route replace 10.88.1.0/24 $nh"; }
CAKE_OFF='for i in rq-wg rq-wg2 rq-wg3; do tc qdisc del dev $i root 2>/dev/null; done; true'
stopall() { for h in $C $S; do rsh $h "cd /root/rq; for f in *_P?.pid *_MT.pid; do kill \$(cat \$f) 2>/dev/null; rm -f \$f; done; sleep 2; echo -n"; done; }
restore() { echo "== restore $(date +%T)"; setrps 0; route 3
  for h in $C $S; do rsh $h "$CAKE_OFF; cd /root/rq; for f in *_P?.pid *_MT.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; true
    echo \"\$MFROLE rps=\$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) \$(ip route show 10.90.0.0/24 | wc -l)/\$(ip route show 10.88.1.0/24 | wc -l) mf=\$(pgrep -c multi-fec-dist)+\$(pgrep -c mmulti-fec-dist) iperf=\$(pgrep -xc iperf3) qdisc=\$(for i in rq-wg rq-wg2 rq-wg3; do tc qdisc show dev \$i | head -1 | cut -d' ' -f2; done | paste -sd/)\""; done; }

# ---- netem: 평소 egress netem(r30 기준선) ↔ 시험 중 ingress IFB netem ----
NETEM_RESTORE='d=$(cat /root/rq/r30_dst); tc qdisc del dev enp4s0 root 2>/dev/null; tc qdisc del dev enp1s0 root 2>/dev/null
  tc qdisc add dev enp4s0 root handle 1: prio bands 4 priomap 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
  tc qdisc add dev enp4s0 parent 1:1 handle 10: netem limit 20000 delay 30ms
  tc qdisc add dev enp4s0 parent 1:2 handle 20: netem limit 20000 delay 54ms
  tc filter add dev enp4s0 parent 1: protocol ip prio 1 u32 match ip dst 172.31.10.$d/32 flowid 1:1
  tc filter add dev enp4s0 parent 1: protocol ip prio 1 u32 match ip dst 172.31.11.$d/32 flowid 1:2
  tc qdisc add dev enp1s0 root handle 8003: netem limit 20000 delay 54ms
  tc qdisc show dev enp4s0 > /root/rq/r30_tc_after.txt; tc qdisc show dev enp1s0 >> /root/rq/r30_tc_after.txt
  tc filter show dev enp4s0 | grep -E "match|flowid" >> /root/rq/r30_tc_after.txt
  if diff -q /root/rq/r30_tc_before.txt /root/rq/r30_tc_after.txt >/dev/null; then echo "$MFROLE netem 복원 일치"; else echo "$MFROLE netem 복원 불일치"; diff /root/rq/r30_tc_before.txt /root/rq/r30_tc_after.txt; fi'
IFB_UP='d=$(cat /root/rq/r30_dst); tc qdisc show dev enp4s0 > /root/rq/r31_tc_before.txt; tc qdisc show dev enp1s0 >> /root/rq/r31_tc_before.txt
  tc filter show dev enp4s0 | grep -E "match|flowid" >> /root/rq/r31_tc_before.txt
  cp /root/rq/r31_tc_before.txt /root/rq/r30_tc_before.txt
  tc qdisc del dev enp4s0 root; tc qdisc del dev enp1s0 root
  ip link add ifb4 type ifb && ip link set ifb4 up; ip link add ifb1 type ifb && ip link set ifb1 up
  tc qdisc add dev ifb4 root handle 1: prio bands 4 priomap 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
  tc qdisc add dev ifb4 parent 1:1 handle 10: netem limit 20000 delay 30ms
  tc qdisc add dev ifb4 parent 1:2 handle 20: netem limit 20000 delay 54ms
  tc filter add dev ifb4 parent 1: protocol ip prio 1 u32 match ip src 172.31.10.$d/32 flowid 1:1
  tc filter add dev ifb4 parent 1: protocol ip prio 1 u32 match ip src 172.31.11.$d/32 flowid 1:2
  tc qdisc add dev ifb1 root handle 1: prio bands 4 priomap 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3 3
  tc qdisc add dev ifb1 parent 1:1 handle 10: netem limit 20000 delay 54ms
  tc filter add dev ifb1 parent 1: protocol ip prio 1 u32 match ip src 172.31.20.$d/32 flowid 1:1
  tc qdisc add dev enp4s0 handle ffff: ingress
  tc filter add dev enp4s0 parent ffff: protocol ip prio 1 u32 match ip src 172.31.0.0/16 action mirred egress redirect dev ifb4
  tc qdisc add dev enp1s0 handle ffff: ingress
  tc filter add dev enp1s0 parent ffff: protocol ip prio 1 u32 match ip src 172.31.0.0/16 action mirred egress redirect dev ifb1
  echo "$MFROLE IFB: $(tc qdisc show dev ifb4 | grep -c netem)+$(tc qdisc show dev ifb1 | grep -c netem) netem, ingress $(tc qdisc show dev enp4s0 ingress | wc -l)/$(tc qdisc show dev enp1s0 ingress | wc -l), egress root $(tc qdisc show dev enp4s0 | head -1 | cut -c1-30)"'
IFB_DOWN='tc qdisc del dev enp4s0 ingress 2>/dev/null; tc qdisc del dev enp1s0 ingress 2>/dev/null; ip link del ifb4 2>/dev/null; ip link del ifb1 2>/dev/null
  echo "$MFROLE IFB 제거: ifb $(ip -br link show type ifb | wc -l) ingress $(tc qdisc show dev enp4s0 ingress | wc -l)/$(tc qdisc show dev enp1s0 ingress | wc -l)"'
restore2() { restore; for h in $C $S; do rsh $h "$IFB_DOWN"; rsh $h "$NETEM_RESTORE"; done; }
# 시험 환경 올리기: 정리 trap 을 먼저 건 뒤 IFB 로 옮긴다(중간에 실패해도 원복되게).
env_up() {
  rsh $C 'echo 1 > /root/rq/r30_dst'; rsh $S 'echo 2 > /root/rq/r30_dst'
  trap restore2 EXIT
  for h in $C $S; do rsh $h "$IFB_UP"; done
  echo "-- 하부 ping (기대 RTT 60 / 108 ms)"
  rsh $C 'for a in 172.31.10.1 172.31.11.1 172.31.20.1; do echo "$a $(ping -c 5 -i 0.2 -q $a | tail -1)"; done'; }
# 손실 x %, r=1 이면 경로 A 100 Mbit / B 50 Mbit 제한
setnet() { local x=$1 r=$2 RA="limit 20000" RB="limit 20000" h
  [ "$r" = 1 ] && { RA="limit 750 rate 100mbit"; RB="limit 500 rate 50mbit"; }
  for h in $C $S; do rsh $h "tc qdisc change dev ifb4 parent 1:1 handle 10: netem $RA delay 30ms loss $x%; tc qdisc change dev ifb4 parent 1:2 handle 20: netem limit 20000 delay 54ms loss $x%; tc qdisc change dev ifb1 parent 1:1 handle 10: netem $RB delay 54ms loss $x%; echo \"  \$MFROLE A: \$(tc qdisc show dev ifb4 parent 1:1 | cut -d' ' -f6-) / B: \$(tc qdisc show dev ifb1 parent 1:1 | cut -d' ' -f6-)\""; done; }

# ---- 측정 ----
bins() { for h in $C $S; do rsh $h 'cd /root/rq; echo "$MFROLE spd2 $(md5sum multi-fec-dist.spd2 | cut -c1-12) mt $(md5sum mmulti-fec-dist | cut -c1-12) $(./mmulti-fec-dist --version | head -1)"'; done; }
mbps() { awk '/SUM.*receiver/{f=1} /receiver/{l=$0} END{print l}' "$1" | awk '{for(i=1;i<=NF;i++) if($i ~ /bits\/sec/){v=$(i-1); if($i ~ /^G/) v*=1000; if($i ~ /^K/) v/=1000; print v}}'; }
idle() { local h; for h in $C $S; do rsh $h "awk '/^Average/ && \$2 ~ /^[0-9]+\$/ {printf \"%.0f \", \$NF}' /root/rq/${RUN}_$1_mpstat.txt"; echo -n "/ "; done; }
QS='for d in ifb4 ifb1; do tc -s qdisc show dev $d parent 1:1 | awk "/Sent/{b=\$2; for(i=1;i<=NF;i++) if(\$i==\"(dropped\") {x=\$(i+1); sub(\",\",\"\",x)}} END{printf \"%s %s \", b, x}"; done'
qsnap() { local h; for h in $C $S; do rsh $h "$QS"; done; }
# run 이름 병렬수 iperf추가인자 — 30초 iperf3 + ping + mpstat + rcvbuf + IFB 큐 버림
run() { local name=$1 P=$2 A=$3 q0 q1 qd ub rt pg h; q0=$(qsnap)
  for h in $C $S; do rsh $h "nstat -n; cd /root/rq; (LC_ALL=C mpstat -P ALL 1 32 > ${RUN}_${name}_mpstat.txt 2>&1 < /dev/null &)"; done
  rsh $C "cd /root/rq; (ip netns exec ue ping -i 0.2 -c 150 -W 2 10.90.0.10 > ${RUN}_${name}_ping.txt 2>&1 &)"
  rsh $C "ip netns exec ue iperf3 -c 10.90.0.10 -P $P -t 30 $A" > "$RAW/iperf_$name.txt" 2>&1
  sleep 3; rsh $C "cat /root/rq/${RUN}_${name}_ping.txt" > "$RAW/ping_$name.txt"
  ub=$(for h in $C $S; do rsh $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n "/"; done)
  rt=$(grep -E "sender" "$RAW/iperf_$name.txt" | tail -1 | awk '{print $(NF-1)}')
  pg=$(grep -o 'time=[0-9.]*' "$RAW/ping_$name.txt" | cut -d= -f2 | sort -n | awk '{v[NR]=$1} END{if(NR) printf "p50 %.0f p99 %.0f n=%d", v[int(NR*0.5)+1], v[(int(NR*0.99)>0)?int(NR*0.99):1], NR}')
  q1=$(qsnap); qd=$(echo $q0 $q1 | awk '{printf "c drop %d/%d MB %.0f/%.0f  s drop %d/%d MB %.0f/%.0f", $10-$2,$12-$4,($9-$1)/1e6,($11-$3)/1e6, $14-$6,$16-$8,($13-$5)/1e6,($15-$7)/1e6}')
  echo "  $name recv $(mbps "$RAW/iperf_$name.txt") | retr $rt | ping $pg | idle c/s $(idle $name)| rcvbuf c/s $ub | q(A100/B50) $qd"; sleep 4; }
# variant 의 multi-fec 로그 요약(로그 이름 *_${RUN}_<v>.log)
logsum() { local v=$1 h
  for h in $C $S; do rsh $h "cd /root/rq; grep -saE 'pending enq' *_${RUN}_$v.log | tail -3 | sed 's/\x1b\[[0-9;]*m//g' | cut -c22- | sed 's/^/  '\$MFROLE' /'"; done
  rsh $C "cd /root/rq; echo \"  client EAGAIN \$(cat *_${RUN}_$v.log | grep -c EAGAIN) pendfull \$(cat *_${RUN}_$v.log | grep -c 'pending queue full') err \$(cat *_${RUN}_$v.log | grep -cE 'ERROR|FATAL') winlog \$(grep -h 'send window' *_${RUN}_$v.log | sed 's/.*send window: //' | sort | uniq -c | tr -s ' ' | paste -sd,)\""; }
