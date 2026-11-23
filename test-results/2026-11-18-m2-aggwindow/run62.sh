#!/bin/bash
# run62 — 권장 A(--workers 3 --worker-cpus 0,1,2, 기본값)에서 동시 30세션(상향 -P15 + 하향 -R -P15 동시) 손실 1 %.
#   손실은 egress netem(30/54 ms) — run61 에서 기본(GSO 켬)은 netem 이 GSO 묶음째 버려 시험망 고유의 붕괴가 나므로,
#   회선 손실(패킷 단위)에 해당하는 E01(MF_UDP_GSO=0, client·server)로 손실 1 % 를 재고, 손실 0 % 는 E11(기본)·E01 둘 다 잰다.
#   순서: l0_E11 → l0_E01 → l1_E01_1 → l1_E01_2 → l0_E11_2 (기본 손실 0 % 로 앞뒤를 감싸 drift 확인). 구간당 DUR 초(기본 300).
#   mt.2 10b361ea, rps 8, 터널 1개, IFB 없음. 구간마다 multi-fec 새로 띄움.
# 2026-11-23 사용자 "권장 A로 30세션 손실 1% 시험 진행해줘".
RUN=r62; RAW=raw62
cd "$(dirname "$0")"; . ./lib.sh
DUR=${DUR:-300}
echo "== setup $(date +%T) DUR=$DUR"
bins
[ "${DRY:-0}" = 1 ] && { echo "DRY=1 — 여기서 끝(상태 변경 없음)"; trap - EXIT; exit 0; }

for h in $C $S; do rsh $h "cd /root/rq; for f in *.pid; do kill \$(cat \$f) 2>/dev/null; done; pkill -x iperf3; sleep 1; $CAKE_OFF"; done
rsh $S "cd /root/rq; for p in 5201 5202; do (setsid timeout 3600 ip netns exec hq iperf3 -s -p \$p > iperf_hq_${RUN}_\$p.log 2>&1 < /dev/null &); done"
rsh $C 'echo 1 > /root/rq/r30_dst'; rsh $S 'echo 2 > /root/rq/r30_dst'
for h in $C $S; do rsh $h 'tc qdisc show dev enp4s0 > /root/rq/r30_tc_before.txt; tc qdisc show dev enp1s0 >> /root/rq/r30_tc_before.txt; tc filter show dev enp4s0 | grep -E "match|flowid" >> /root/rq/r30_tc_before.txt; echo "$MFROLE egress 기준 저장 $(grep -c netem /root/rq/r30_tc_before.txt) netem, ifb $(ip -br link show type ifb | wc -l)"'; done
trap restore2 EXIT
echo "-- 하부 ping (기대 RTT 60 / 108 ms)"
rsh $C 'for a in 172.31.10.1 172.31.11.1 172.31.20.1; do echo "$a $(ping -c 5 -i 0.2 -q $a | tail -1)"; done'

esetnet() { local x=$1 h
  for h in $C $S; do rsh $h "tc qdisc change dev enp4s0 parent 1:1 handle 10: netem limit 20000 delay 30ms loss $x%; tc qdisc change dev enp4s0 parent 1:2 handle 20: netem limit 20000 delay 54ms loss $x%; tc qdisc change dev enp1s0 root handle 8003: netem limit 20000 delay 54ms loss $x%; echo \"  \$MFROLE \$(tc qdisc show dev enp4s0 | grep -o 'netem [0-9]*:.*' | paste -sd' ') | \$(tc qdisc show dev enp1s0 | grep -o 'netem [0-9]*:.*')\""; done; }
# egress netem 3개 합계: 바이트 · 패킷(세그먼트 단위) · 버림(skb 단위) — 호스트당 6개 수
ESZ='tc -s qdisc show dev enp4s0 | awk "/^qdisc netem/{f=1; next} /^qdisc/{f=0} f && /Sent/{b+=\$2; p+=\$4; x=\$7; sub(\",\",\"\",x); d+=x; f=0} END{printf \"%d %d %d \", b, p, d}"
  tc -s qdisc show dev enp1s0 | awk "/^qdisc netem/{f=1; next} /^qdisc/{f=0} f && /Sent/{b+=\$2; p+=\$4; x=\$7; sub(\",\",\"\",x); d+=x; f=0} END{printf \"%d %d %d\", b, p, d}"'
esnap() { local h; for h in $C $S; do rsh $h "$ESZ"; echo -n " "; done; }
# 호스트 상태: 프로세스 수 · RSS 합(KB) · netns TCP 재전송 누계
HS='mf=$(pgrep -d" " -f "^[^ ]*mmulti-fec-dist --config"); r=0; for p in $mf; do r=$((r + $(awk "/VmRSS/{print \$2}" /proc/$p/status))); done
  ns=$(ip netns list | cut -d" " -f1); rt=$(ip netns exec $ns awk "/^Tcp:/{c++} /^Tcp:/ && c==2{print \$13}" /proc/net/snmp); echo "$(echo $mf | wc -w) $r $rt"'

start() { local v=$1 kind=$2 EV pair; stopall; setrps 8; route 1
  case $kind in E11) EV="";; E01) EV="MF_UDP_GSO=0";; esac
  for pair in "$S server" "$C client"; do set -- $pair
    rsh $1 "cd /root/rq; $EV setsid timeout $((DUR + 300)) ./mmulti-fec-dist --config /root/rq/${2}_P0.conf --workers 3 --worker-cpus 0,1,2 > ${2}_MT_${RUN}_$v.log 2>&1 < /dev/null & echo \$! > ${2}_MT.pid"; done
  sleep 10
  rsh $C "ip netns exec ue ping -c 3 -i 0.3 -q 10.90.0.10 | tail -1; echo \"  route \$(ip route show 10.90.0.0/24 | wc -l) rps \$(cat /sys/class/net/lo/queues/rx-0/rps_cpus) procs \$(pgrep -c mmulti-fec-dist)\""
  for pair in "$C client" "$S server"; do set -- $pair
    rsh $1 "cd /root/rq; echo \"  \$MFROLE env GSO=0:\$(grep -ac MF_UDP_GSO=0 /proc/\$(cat ${2}_MT.pid)/environ)\""; done; }

phase() { local v=$1 kind=$2 s0 s1 h0 h1 f
  echo "== $v ($kind) $(date +%T)"; start $v $kind
  s0=$(esnap); h0=$(for h in $C $S; do rsh $h "$HS"; done | paste -sd' ')
  for h in $C $S; do rsh $h "nstat -n; cd /root/rq; (LC_ALL=C mpstat -P ALL $DUR 1 > ${RUN}_${v}_mpstat.txt 2>&1 < /dev/null &)"; done
  rsh $C "cd /root/rq
    (setsid timeout $((DUR + 60)) ip netns exec ue iperf3 -c 10.90.0.10 -p 5201 -P 15 -t $DUR -i 10 --forceflush > ${RUN}_${v}_up.txt 2>&1 < /dev/null &)
    (setsid timeout $((DUR + 60)) ip netns exec ue iperf3 -c 10.90.0.10 -p 5202 -P 15 -t $DUR -i 10 --forceflush -R > ${RUN}_${v}_dn.txt 2>&1 < /dev/null &)
    (setsid timeout $((DUR + 60)) ip netns exec ue ping -D -i 0.2 -c $((DUR * 5)) -W 2 10.90.0.10 > ${RUN}_${v}_ping.txt 2>&1 < /dev/null &)"
  sleep $((DUR + 8))
  while rsh $C "pgrep -xc iperf3 >/dev/null"; do sleep 3; done
  s1=$(esnap); h1=$(for h in $C $S; do rsh $h "$HS"; done | paste -sd' ')
  for f in up dn ping; do rsh $C "cat /root/rq/${RUN}_${v}_$f.txt" > "$RAW/${f}_$v.txt"; done
  echo "  up recv $(mbps "$RAW/up_$v.txt") retr $(grep SUM "$RAW/up_$v.txt" | grep sender | awk '{print $(NF-1)}') | dn recv $(mbps "$RAW/dn_$v.txt") retr $(grep SUM "$RAW/dn_$v.txt" | grep sender | awk '{print $(NF-1)}')"
  echo "  ping $(grep -o '[0-9.]*% packet loss' "$RAW/ping_$v.txt") $(grep -o 'time=[0-9.]*' "$RAW/ping_$v.txt" | cut -d= -f2 | sort -n | awk '{v[NR]=$1} END{if(NR) printf "p50 %.0f p90 %.0f p99 %.0f max %.0f", v[int(NR*0.5)+1], v[int(NR*0.9)+1], v[int(NR*0.99)], v[NR]}')"
  # esnap: 앞 6 = client(b1 p1 d1 b2 p2 d2), 뒤 6 = server
  echo $s0 $s1 | awk '{cp=($14-$2)+($17-$5); cd=($15-$3)+($18-$6); sp=($20-$8)+($23-$11); sd=($21-$9)+($24-$12)
    printf "  egress netem 버림/세그먼트  client %d/%d (%.2f %%)  server %d/%d (%.2f %%)\n", cd, cp, cp?100*cd/cp:0, sd, sp, sp?100*sd/sp:0}'
  # HS: client(n rss rt) server(n rss rt)
  echo $h0 $h1 | awk '{printf "  procs c/s %d/%d  RSS KB c %d→%d s %d→%d  netns 재전송 c %d s %d\n", $7, $10, $2, $8, $5, $11, $9-$3, $12-$6}'
  echo "  CPU 유휴 c/s $(for h in $C $S; do rsh $h "awk '/^Average/ && \$2==\"all\" {printf \"%.0f\", \$NF}' /root/rq/${RUN}_${v}_mpstat.txt"; echo -n " "; done)| rcvbuf c/s $(for h in $C $S; do rsh $h "nstat -z UdpRcvbufErrors | awk '/Udp/{printf \$2}'"; echo -n " "; done)"
  logsum $v
  for h in $C $S; do rsh $h "cd /root/rq; echo \"  \$MFROLE 'no RUNNING path' \$(grep -ac 'no RUNNING path' *_MT_${RUN}_$v.log) · stale 폐기 \$(grep -aciE 'stale|discard' *_MT_${RUN}_$v.log)\""; done
  sleep 3; }

esetnet 0
phase l0_E11 E11
phase l0_E01 E01
esetnet 1
phase l1_E01_1 E01
phase l1_E01_2 E01
esetnet 0
phase l0_E11_2 E11
stopall
rget
echo "done $(date +%T)"
