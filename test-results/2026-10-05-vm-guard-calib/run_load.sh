#!/bin/bash
# run_load.sh — 신규 테스트망(VM) 부하 런: 계단 또는 지속 (2026-10-05, 가드 재보정용)
#
#   RUNID=lad STEPS="10 20 30" DUR=45 ./run_load.sh      # 계단
#   RUNID=soak20 STEPS=20 DUR=900 ./run_load.sh           # 지속 (스텝 1개)
#
# 순서는 절대 규칙대로: ① 가드 precheck·기동 ② 가드 생존 확인 ③ 부하.
# 트래픽은 WG 주소(10.9.20.2 → 10.9.20.1) 사이에서만 (규칙 1).
# 계측은 호스트 로컬 샘플러(mf-hostsamp.sh) — 가드의 ssh 샘플과 독립이다.
set -u
cd "$(dirname "$0")"
RUNID=${RUNID:?}; STEPS=${STEPS:?}; DUR=${DUR:-45}; GAP=${GAP:-5}
G=../2026-08-02-50mbps-soak/mf_gwguard.sh
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
OUT=raw/$RUNID; mkdir -p "$OUT"
export GW_NET=new
: "${GW_PROFILE:=vm}"; export GW_PROFILE

# ① 가드 — precheck 실패 시 watch 가 스스로 exit 3
setsid "$G" watch "mfgen tx" > "$OUT/guard.log" 2>&1 < /dev/null &
GP=$!
sleep 12
# ⚠️ 생존은 PID 로 판정 (pgrep -f 는 호출 셸을 매치한다 — 하네스 함정)
kill -0 $GP 2>/dev/null && grep -q '감시 시작' "$OUT/guard.log" || { echo "가드 기동 실패"; cat "$OUT/guard.log"; exit 2; }
echo "[run] 가드 PID $GP 감시 중 ($GW_PROFILE)"

# 샘플러
for p in "c $C ens18" "r $R ens18,ens19" "s $S ens18"; do set -- $p
  ssh "$2" "setsid nohup /usr/local/sbin/mf-hostsamp.sh /tmp/hs_$RUNID.csv $3 >/dev/null 2>&1 < /dev/null &"
done
sleep 3

stop_all() {
  for p in "c $C" "r $R" "s $S"; do set -- $p
    ssh "$2" "kill \$(cat /tmp/hs_$RUNID.csv.pid) 2>/dev/null"; scp -q "$2:/tmp/hs_$RUNID.csv" "$OUT/hs_$1.csv"; done
  kill $GP 2>/dev/null; pkill -P $GP 2>/dev/null
}
trap stop_all EXIT

: > "$OUT/steps.txt"
for r in $STEPS; do
  kill -0 $GP 2>/dev/null || { echo "[run] 가드 소멸(트립?) — 중단"; tail -3 "$OUT/guard.log"; exit 3; }
  t0=$(date +%s.%N)
  # 부하 = mfgen (iperf3 3.16 UDP 송신은 레이트와 무관하게 1코어를 100% 먹는다 — mfgen.c 주석)
  #   상향 c:tx → s:5301   하향 s:tx → c:5302.  수신기를 먼저 띄우고 DUR+3 초 산다.
  ssh "$S" "mfgen rx 10.9.20.1 5301 $((DUR+4)) > /tmp/g_up_${RUNID}_$r.txt" > /dev/null 2>&1 & RS=$!
  ssh "$C" "mfgen rx 10.9.20.2 5302 $((DUR+4)) > /tmp/g_dn_${RUNID}_$r.txt" > /dev/null 2>&1 & RC=$!
  sleep 1
  ssh "$C" "mfgen tx 10.9.20.1 5301 $r $DUR" > "$OUT/tx_up_$r.txt" 2>&1 & T1=$!
  ssh "$S" "mfgen tx 10.9.20.2 5302 $r $DUR" > "$OUT/tx_dn_$r.txt" 2>&1 & T2=$!
  wait $T1; wait $T2; wait $RS; wait $RC     # ⚠️ 특정 PID 만 기다린다
  scp -q "$S:/tmp/g_up_${RUNID}_$r.txt" "$OUT/up_$r.txt"; scp -q "$C:/tmp/g_dn_${RUNID}_$r.txt" "$OUT/dn_$r.txt"
  t1=$(date +%s.%N); echo "$r $t0 $t1" >> "$OUT/steps.txt"
  printf "[run] %3s Mbps  up %s  dn %s\n" "$r" "$(awk '/^total/{print $9"% ooo "$13}' "$OUT/up_$r.txt")" "$(awk '/^total/{print $9"% ooo "$13}' "$OUT/dn_$r.txt")"
  grep -q '트립' "$OUT/guard.log" && { echo "[run] 가드 트립"; grep 트립 "$OUT/guard.log"; exit 4; }
  sleep $GAP
done
echo "[run] 완료"
