#!/bin/bash
# xver_new.sh — 신규 테스트망(VM) 1.3.1 ↔ 1.3.5 교차 실측 (2026-10-05)
#
# 왜: 서비스망은 전 홉 1.3.1 이다. 1.3.2~1.3.5 는 전부 "와이어 무변경" 으로 기록돼 있지만
#     1.3.1 과 1.3.5 를 섞은 조합은 실측한 적이 없다. 구 망용 mf_xver.sh 는 호스트·다중
#     세션 구조가 박혀 있어 신규 망에 못 쓴다 → 유닛 바이너리 교체 + run_load.sh 로 잰다.
#
# 전제(사전 배치): 각 호스트 /usr/sbin/multi-fec-dist.v1.3.1 · .v1.3.5 · .bak-v1.3.4
#   COMBOS="X0:131:131:131 ..."  (이름:c:r:s)   STEPS/DUR 는 run_load.sh 로 넘긴다.
# 판정: 교체 후 WG 터널 ping(10.9.20.2→10.9.20.1, WG 주소 사이 — 규칙 1)이 60초 안에 통과해야
#   부하를 건다. 실패하면 그 조합은 FAIL 로 남기고 부하 없이 다음으로 간다.
# 정리(1.3.4 복구)는 이 스크립트가 하지 않는다 — 결과를 본 뒤 사람이 확인하며 되돌린다.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
COMBOS=${COMBOS:-"X0:131:131:131 X1:135:131:131 X2:131:135:131 X3:131:131:135 X4:135:135:131 X5:131:135:135 X6:135:135:135"}
STEPS=${STEPS:-"10 20"}; DUR=${DUR:-120}
OUT=raw/xver; mkdir -p "$OUT"
SUM=$OUT/summary.txt

setver() {  # <ssh> <ver 131|135> <units...>
  local h=$1 v=1.3.${2:2}; shift 2
  ssh "$h" "install -m 755 /usr/sbin/multi-fec-dist.v$v /usr/sbin/multi-fec-dist && systemctl restart $*"
}
snap() { for p in "c $C" "r $R" "s $S"; do set -- $p
  echo "$1 $(ssh "$2" 'nstat -az UdpRcvbufErrors | tail -1' | awk '{print $2}')"; done; }

echo "# $(date '+%F %T') STEPS=$STEPS DUR=$DUR" >> "$SUM"
for combo in $COMBOS; do
  IFS=: read -r X VC VR VS <<< "$combo"
  D=$OUT/$X; mkdir -p "$D"
  T0=$(date +%s)
  echo "[$(date +%T)] ===== $X  c=$VC r=$VR s=$VS"
  # 서버 → 릴레이 → 클라 순: 클라가 마지막에 붙어 새 세션을 맺는다
  setver "$S" "$VS" multi-fec-server
  setver "$R" "$VR" multi-fec-relay multi-fec-relay-b
  setver "$C" "$VC" multi-fec-client
  for p in "c $C" "r $R" "s $S"; do set -- $p
    echo "$1 $(ssh "$2" '/usr/sbin/multi-fec-dist --version | head -2 | tr "\n" " "; md5sum /usr/sbin/multi-fec-dist | cut -c1-8')"
  done > "$D/versions.txt"

  ok=0
  for i in $(seq 1 12); do
    ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' > "$D/ping.txt" 2>&1 && { ok=1; break; }
    sleep 5
  done
  if [ $ok -ne 1 ]; then
    echo "[$(date +%T)] $X FAIL: 터널 ping 60초 무응답 — 부하 생략"
    echo "$X c=$VC r=$VR s=$VS FAIL tunnel" >> "$SUM"
  else
    snap > "$D/nstat_before.txt"
    RUNID=xv_$X STEPS="$STEPS" DUR=$DUR ./run_load.sh > "$D/run.out" 2>&1
    rc=$?
    snap > "$D/nstat_after.txt"
    res=$(grep -E '^\[run\] +[0-9]+ Mbps' "$D/run.out" | awk '{printf "%s:up%s/dn%s ", $2, $5, $9}')
    drops=$(paste "$D/nstat_before.txt" "$D/nstat_after.txt" | awk '{printf "%s+%d ", $1, $4-$2}')
    echo "[$(date +%T)] $X rc=$rc  $res  drop $drops"
    echo "$X c=$VC r=$VR s=$VS rc=$rc $res drop $drops" >> "$SUM"
  fi
  # 홉별 로그: 조합 시작 이후 전부, WARN/ERROR 건수 + 클라 경로 상태
  for p in "c $C multi-fec-client" "r $R multi-fec-relay -u multi-fec-relay-b" "s $S multi-fec-server"; do
    set -- $p; n=$1; h=$2; shift 2
    ssh "$h" "journalctl -u $* --since @$T0 --no-pager" > "$D/log_$n.txt" 2>&1
  done
  echo "  warn/err c=$(grep -cE 'WARN|ERROR|FATAL' "$D/log_c.txt") r=$(grep -cE 'WARN|ERROR|FATAL' "$D/log_r.txt") s=$(grep -cE 'WARN|ERROR|FATAL' "$D/log_s.txt")" \
       "  path lines: $(grep -oE 'path\[[01]\] [A-Z]+' "$D/log_c.txt" | sort | uniq -c | tr -s ' ' | tr '\n' ';')" | tee -a "$SUM"
  if [ -f "$D/run.out" ] && grep -qE '트립|소멸|기동 실패' "$D/run.out"; then
    echo "[$(date +%T)] 가드 트립/실패 — 중단"; echo "$X GUARD STOP" >> "$SUM"; exit 4
  fi
done
echo "[$(date +%T)] 완료"
