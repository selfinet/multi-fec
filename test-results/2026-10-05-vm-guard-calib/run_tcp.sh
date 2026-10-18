#!/bin/bash
# run_tcp.sh — run_load.sh 의 TCP 판 (2026-10-17): 부하만 iperf3 TCP 로 바꿨다.
#   상향 c→s(:5201) · 하향 s→c(:5202) 를 각자 송신 호스트에서 띄운다. 레이트는 --fq-rate(커널 페이싱)만 건다.
#   ⚠️ -b 를 쓰면 iperf3 3.16 이 TCP 에서도 1코어를 100% 돌려 가드가 트립한다(2026-10-17 23:26 실측, multi-fec CPU 는 14~24%).
# 가드·샘플러·steps.txt 형식은 run_load.sh 와 같다. 결과는 $OUT/tcp_{up,dn}_<레이트>.json
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
setsid "$G" watch "iperf3 -c" > "$OUT/guard.log" 2>&1 < /dev/null &
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
  # 부하 = iperf3 TCP 1스트림씩, 방향별 독립 세션. 서버는 1회용(-1). 정리는 comm 정확 매치(-x) — pkill -f 금지(하네스 함정)
  ssh "$S" "iperf3 -s -B 10.9.20.1 -p 5201 -1 -D"; ssh "$C" "iperf3 -s -B 10.9.20.2 -p 5202 -1 -D"; sleep 1
  ssh "$C" "timeout $((DUR+40)) iperf3 -c 10.9.20.1 -B 10.9.20.2 -p 5201 --fq-rate ${r}M -t $DUR -i 1 -J" > "$OUT/tcp_up_$r.json" 2> "$OUT/tcp_up_$r.err" & T1=$!
  ssh "$S" "timeout $((DUR+40)) iperf3 -c 10.9.20.2 -B 10.9.20.1 -p 5202 --fq-rate ${r}M -t $DUR -i 1 -J" > "$OUT/tcp_dn_$r.json" 2> "$OUT/tcp_dn_$r.err" & T2=$!
  wait $T1; wait $T2     # ⚠️ 특정 PID 만 기다린다
  ssh "$S" "pkill -x iperf3; exit 0"; ssh "$C" "pkill -x iperf3; exit 0"
  t1=$(date +%s.%N); echo "$r $t0 $t1" >> "$OUT/steps.txt"
  printf "[run] %3s Mbps  up %s  dn %s\n" "$r" "$(python3 tcpsum.py "$OUT/tcp_up_$r.json")" "$(python3 tcpsum.py "$OUT/tcp_dn_$r.json")"
  grep -q '트립' "$OUT/guard.log" && { echo "[run] 가드 트립"; grep 트립 "$OUT/guard.log"; exit 4; }
  sleep $GAP
done
echo "[run] 완료"
