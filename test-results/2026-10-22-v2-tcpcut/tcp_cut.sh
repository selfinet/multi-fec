#!/bin/bash
# tcp_cut.sh — WG 터널 위 TCP 절단 시험: 1.4.0 vs 1.4.1-v2 (2026-10-22, 테스트망 전용)
#   부하: iperf3 TCP 1스트림 상향 c→s(:5201)·하향 s→c(:5202), --fq-rate 만 (-b 금지: 3.16 은 1코어 100%)
#   절단: CUT_AT 초에 relay 프로세스 정지 → UP_AT 초에 기동 (tunnel_regress.sh 와 같은 방식)
#   작업: /usr/sbin/multi-fec-dist 를 .v<버전> 으로 install → multi-fec@* 재시작. 영향: 교체마다 터널 1초 안팎 끊김
#   되돌리기: 끝나면(중단돼도) relay 기동 + .v1.4.0 복원
set -u
cd "$(dirname "$0")"
REPS=${REPS:-3}; RATE=${RATE:-15}; DUR=${DUR:-90}; CUT_AT=${CUT_AT:-20}; UP_AT=${UP_AT:-60}; GAP=${GAP:-8}
VERS=${VERS:-"1.4.0 1.4.1-v2"}; SCEN=${SCEN:-"steady cut1 cut0"}
G=../2026-08-02-50mbps-soak/mf_gwguard.sh
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
OUT=raw; mkdir -p $OUT
export GW_NET=new GW_PROFILE=${GW_PROFILE:-vm}
sv1() { echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"; }
echo "[$(date +%T)] $(sv1)"

setsid "$G" watch "iperf3 -c" > $OUT/guard.log 2>&1 < /dev/null &
GP=$!; sleep 12
kill -0 $GP 2>/dev/null && grep -q '감시 시작' $OUT/guard.log || { echo "가드 기동 실패"; cat $OUT/guard.log; exit 2; }
echo "[run] 가드 PID $GP 감시 중"

setver() {
  ssh "$S" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@server"
  ssh "$R" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@relay multi-fec@relay-b"
  ssh "$C" "install -m 755 /usr/sbin/multi-fec-dist.v$1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec@client"
  for i in $(seq 1 12); do ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done
  echo "  설치 $(for h in $C $R $S; do ssh "$h" 'sha256sum /usr/sbin/multi-fec-dist | cut -c1-12'; done | sort | uniq -c | tr '\n' ' ')"
  sleep 20
}
finish() {
  echo "[$(date +%T)] ===== 정리"
  ssh "$S" "pkill -x iperf3; exit 0"; ssh "$C" "pkill -x iperf3; exit 0"
  ssh "$R" 'systemctl start multi-fec@relay multi-fec@relay-b'
  kill $GP 2>/dev/null; pkill -P $GP 2>/dev/null
  setver 1.4.0
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@relay-b multi-fec@server 2>/dev/null | tr "\n" " ")"'
  done
  ssh "$C" 'ping -c 5 -i 0.3 -W 1 -q 10.9.20.1 | tail -1'
  echo "[$(date +%T)] $(sv1)"
}
trap finish EXIT
unit_of() { case $1 in cut1) echo multi-fec@relay-b;; cut0) echo multi-fec@relay;; esac; }

for rep in $(seq 1 $REPS); do
 for v in $VERS; do
  echo "[$(date +%T)] ##### rep$rep v$v"; setver $v
  for sc in $SCEN; do
    kill -0 $GP 2>/dev/null || { echo "[run] 가드 소멸 — 중단"; tail -3 $OUT/guard.log; exit 3; }
    tag=${v}_${sc}_$rep
    ssh "$S" "iperf3 -s -B 10.9.20.1 -p 5201 -1 -D"; ssh "$C" "iperf3 -s -B 10.9.20.2 -p 5202 -1 -D"; sleep 1
    ssh "$C" "timeout $((DUR+40)) iperf3 -c 10.9.20.1 -B 10.9.20.2 -p 5201 --fq-rate ${RATE}M -t $DUR -i 1 -J" > $OUT/up_$tag.json 2>/dev/null & T1=$!
    ssh "$S" "timeout $((DUR+40)) iperf3 -c 10.9.20.2 -B 10.9.20.1 -p 5202 --fq-rate ${RATE}M -t $DUR -i 1 -J" > $OUT/dn_$tag.json 2>/dev/null & T2=$!
    if [ "$sc" != steady ]; then
      u=$(unit_of $sc); sleep $CUT_AT; ssh "$R" "systemctl stop $u"; sleep $((UP_AT-CUT_AT)); ssh "$R" "systemctl start $u"
    fi
    wait $T1; wait $T2
    ssh "$S" "pkill -x iperf3; exit 0"; ssh "$C" "pkill -x iperf3; exit 0"
    printf "[run] %-9s %-6s rep%s  up %s  dn %s\n" "$v" "$sc" "$rep" "$(python3 tcpcut_sum.py $OUT/up_$tag.json $CUT_AT $UP_AT)" "$(python3 tcpcut_sum.py $OUT/dn_$tag.json $CUT_AT $UP_AT)"
    grep -q '트립' $OUT/guard.log && { echo "[run] 가드 트립"; grep 트립 $OUT/guard.log; exit 4; }
    sleep $GAP
  done
 done
done
echo "[$(date +%T)] TCPCUT_DONE"
