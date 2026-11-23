#!/bin/bash
# run59 — 손실 1 % 붕괴(run47)가 수신 UDP GRO 뒤 IFB netem 의 "묶음 손실" 탓인지 가리기.
#   G1 = 기본(GSO·GRO 켬) · G0 = MF_UDP_GRO=0(client·server 둘 다). mt.2 10b361ea, --workers 3 --worker-cpus 0,1,2, rps 8, 터널 1개.
#   손실 0 % ×1 → 손실 1 % ×2(교대). IFB 통과 평균 크기(바이트/패킷)로 GRO 묶음 여부를 직접 확인한다.
# 2026-11-23 사용자 "MF_UDP_GRO=0 으로 손실 1% 재시험 진행해줘".
RUN=r59; RAW=raw59
cd "$(dirname "$0")"; . ./lib.sh
echo "== setup $(date +%T)"
bins
[ "${DRY:-0}" = 1 ] && { echo "DRY=1 — 여기서 끝(상태 변경 없음)"; trap - EXIT; exit 0; }

for h in $C $S; do rsh $h "cd /root/rq; for f in *.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; sleep 1; $CAKE_OFF"; done
rsh $S "cd /root/rq; (setsid timeout 7200 ip netns exec hq iperf3 -s > iperf_hq_${RUN}.log 2>&1 < /dev/null &)"
env_up

# IFB(ifb4 경로 A·B + ifb1) 누적 바이트·패킷 — 평균 크기 > 1500 이면 GRO 로 묶인 덩어리가 netem 을 지난 것
SZ='for d in ifb4 ifb1; do tc -s qdisc show dev $d | awk "/^qdisc prio/{f=1} f && /Sent/{print \$2, \$4; exit}"; done | awk "{b+=\$1; p+=\$2} END{printf \"%d %d\", b, p}"'
szsnap() { local h; for h in $C $S; do rsh $h "$SZ"; echo -n " "; done; }

start() { local v=$1 kind=$2 EV pair; stopall; setrps 8; route 1
  case $kind in G1) EV="";; G0) EV="MF_UDP_GRO=0";; esac
  for pair in "$S server" "$C client"; do set -- $pair
    rsh $1 "cd /root/rq; $EV setsid timeout 1500 ./mmulti-fec-dist --config /root/rq/${2}_P0.conf --workers 3 --worker-cpus 0,1,2 > ${2}_MT_${RUN}_$v.log 2>&1 < /dev/null & echo \$! > ${2}_MT.pid"; done
  sleep 10
  rsh $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; echo \"  route \$(ip route show 10.90.0.0/24 | wc -l) rps \$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) procs \$(pgrep -c mmulti-fec-dist)\""
  for pair in "$C client" "$S server"; do set -- $pair
    rsh $1 "cd /root/rq; echo \"  \$MFROLE MF_UDP_GRO=0 in env: \$(grep -ac MF_UDP_GRO=0 /proc/\$(cat ${2}_MT.pid)/environ)\""; done; }
variant() { local v=$1 kind=$2 s0 s1
  echo "== $v ($kind) $(date +%T)"; start $v $kind
  s0=$(szsnap)
  run ${v}_p1_up 1 ""; run ${v}_p1_dn 1 "-R"; run ${v}_p8_up 8 ""; run ${v}_p8_dn 8 "-R"
  s1=$(szsnap)
  echo $s0 $s1 | awk '{printf "  IFB 평균 크기 B/pkt  client %.0f  server %.0f  (패킷 %d / %d)\n", ($5-$1)/(($6-$2)?($6-$2):1), ($7-$3)/(($8-$4)?($8-$4):1), $6-$2, $8-$4}'
  logsum $v
  rsh $C "cd /root/rq; grep -ah 'batch gso' client_MT_${RUN}_$v.log | tail -1 | sed 's/\x1b\[[0-9;]*m//g' | cut -c22-"; }

setnet 0 0
variant l0_G1 G1; variant l0_G0 G0
setnet 1 0
for r in 1 2; do variant l1_G1_$r G1; variant l1_G0_$r G0; done
stopall
rget
echo "done $(date +%T)"
