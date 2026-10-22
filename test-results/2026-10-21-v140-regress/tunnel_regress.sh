#!/bin/bash
# tunnel_regress.sh — 1.4.0 실터널 회귀 (2026-10-21, 테스트망 전용)
#
# 왜: netns 하네스(test_path_failure.py, 5000 pps)는 r(2 vCPU)을 100% 로 포화시켜 가드가 트립한다.
#     그 상태에서 본 duplicate 간헐 대손실(클라 송신 창 고갈 → pending 큐 넘침)이 실제 구성에서도
#     나는지를, 배포 그대로의 multi-fec@ 유닛·WG 터널 위에서 본다. 바이너리·설정은 바꾸지 않는다.
#
# 시나리오 (각 DUR 초, mfgen 양방향 R Mbps, WG 10.9.20.2 ↔ 10.9.20.1 만 — 규칙 1)
#   steady  절단 없음
#   cut1    CUT_AT 초에 multi-fec@relay-b(path[1]) 정지 → UP_AT 초에 시작
#   cut0    같은 방식으로 multi-fec@relay(path[0])
# 산출: raw/<RUNID>/{up,dn}_*.txt(mfgen 초당 손실) · cli_*.log/srv_*.log(구간 저널) · guard.log · hs_*.csv
#
#   RUNID=r1 RATES="10 20" REPS=3 ./tunnel_regress.sh
set -u
cd "$(dirname "$0")"
RUNID=${RUNID:?}; RATES=${RATES:-"10 20"}; REPS=${REPS:-3}
DUR=${DUR:-90}; CUT_AT=${CUT_AT:-20}; UP_AT=${UP_AT:-60}; GAP=${GAP:-10}
SCEN=${SCEN:-"steady cut1 cut0"}
G=../2026-08-02-50mbps-soak/mf_gwguard.sh
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
OUT=raw/$RUNID; mkdir -p "$OUT"
export GW_NET=new GW_PROFILE=${GW_PROFILE:-vm}

sv1() { echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"; }
echo "[$(date +%T)] $(sv1)" | tee "$OUT/sv1.txt"

# ① 가드 — precheck 실패 시 watch 가 스스로 exit 3. 트립하면 mfgen 을 죽인다.
setsid "$G" watch "mfgen tx" > "$OUT/guard.log" 2>&1 < /dev/null &
GP=$!
sleep 12
kill -0 $GP 2>/dev/null && grep -q '감시 시작' "$OUT/guard.log" || { echo "가드 기동 실패"; cat "$OUT/guard.log"; exit 2; }
echo "[run] 가드 PID $GP 감시 중"

for p in "c $C ens18" "r $R ens18,ens19" "s $S ens18"; do set -- $p
  ssh "$2" "setsid nohup /usr/local/sbin/mf-hostsamp.sh /tmp/hs_$RUNID.csv $3 >/dev/null 2>&1 < /dev/null &"
done

finish() {
  echo "[$(date +%T)] ===== 정리"
  ssh "$R" 'systemctl start multi-fec@relay multi-fec@relay-b'    # 절단 중 중단돼도 반드시 되살린다
  for p in "c $C" "r $R" "s $S"; do set -- $p
    ssh "$2" "kill \$(cat /tmp/hs_$RUNID.csv.pid) 2>/dev/null"; scp -q "$2:/tmp/hs_$RUNID.csv" "$OUT/hs_$1.csv"; done
  kill $GP 2>/dev/null; pkill -P $GP 2>/dev/null
  sleep 5
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@relay-b multi-fec@server 2>/dev/null | tr "\n" " ")"'
  done | tee -a "$OUT/sv1.txt"
  ssh "$C" 'ping -c 5 -i 0.3 -W 1 -q 10.9.20.1 | tail -1' | tee -a "$OUT/sv1.txt"
  echo "[$(date +%T)] $(sv1)" | tee -a "$OUT/sv1.txt"
}
trap finish EXIT

unit_of() { case $1 in cut1) echo multi-fec@relay-b;; cut0) echo multi-fec@relay;; esac; }

for rep in $(seq 1 $REPS); do
 for r in $RATES; do
  for sc in $SCEN; do
    kill -0 $GP 2>/dev/null || { echo "[run] 가드 소멸(트립?) — 중단"; tail -3 "$OUT/guard.log"; exit 3; }
    tag=${sc}_${r}_$rep; t0=$(date +%s)
    ssh "$S" "mfgen rx 10.9.20.1 5301 $((DUR+4)) > /tmp/g_up_$tag.txt" > /dev/null 2>&1 & RS=$!
    ssh "$C" "mfgen rx 10.9.20.2 5302 $((DUR+4)) > /tmp/g_dn_$tag.txt" > /dev/null 2>&1 & RC=$!
    sleep 1
    ssh "$C" "mfgen tx 10.9.20.1 5301 $r $DUR" > "$OUT/tx_up_$tag.txt" 2>&1 & T1=$!
    ssh "$S" "mfgen tx 10.9.20.2 5302 $r $DUR" > "$OUT/tx_dn_$tag.txt" 2>&1 & T2=$!
    if [ "$sc" != steady ]; then
      u=$(unit_of $sc)
      sleep $CUT_AT; ssh "$R" "systemctl stop $u"; echo "$(date +%s) stop $u" >> "$OUT/events_$tag.txt"
      sleep $((UP_AT-CUT_AT)); ssh "$R" "systemctl start $u"; echo "$(date +%s) start $u" >> "$OUT/events_$tag.txt"
    fi
    wait $T1; wait $T2; wait $RS; wait $RC     # 특정 PID 만 기다린다
    scp -q "$S:/tmp/g_up_$tag.txt" "$OUT/up_$tag.txt"; scp -q "$C:/tmp/g_dn_$tag.txt" "$OUT/dn_$tag.txt"
    ssh "$S" "rm -f /tmp/g_up_$tag.txt"; ssh "$C" "rm -f /tmp/g_dn_$tag.txt"
    ssh "$C" "journalctl -u multi-fec@client --since @$t0 --no-pager -o short-unix" | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/cli_$tag.log"
    ssh "$S" "journalctl -u multi-fec@server --since @$t0 --no-pager -o short-unix" | sed 's/\x1b\[[0-9;]*m//g' > "$OUT/srv_$tag.log"
    printf "[run] %-6s %2s Mbps rep%s  up %s  dn %s  cliEAGAIN %s  srvEAGAIN %s\n" "$sc" "$r" "$rep" \
      "$(awk '/^total/{print $9"%"}' "$OUT/up_$tag.txt")" "$(awk '/^total/{print $9"%"}' "$OUT/dn_$tag.txt")" \
      "$(grep -c 'EAGAIN' "$OUT/cli_$tag.log")" "$(grep -c 'EAGAIN' "$OUT/srv_$tag.log")" | tee -a "$OUT/summary.txt"
    grep -q '트립' "$OUT/guard.log" && { echo "[run] 가드 트립"; grep 트립 "$OUT/guard.log"; exit 4; }
    sleep $GAP
  done
 done
done
echo "[run] 완료" | tee -a "$OUT/summary.txt"
