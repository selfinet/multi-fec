#!/bin/bash
# xver2_route.sh — 신규 테스트망 **2단 `--route`** 구성에서 1.3.1 ↔ 1.3.5 교차 실측 (2026-10-06)
#
# 왜: xver_new.sh(§9)는 릴레이 1단 `--upstream` 이었다. 서비스망은 지사→1단→2단→서버 이고
#     양 단 모두 `--route "KEY 상류"` 다. 그 구성에서 버전을 섞는 경우를 잰다.
#
# 구성 (r 한 VM 안에 2단을 추가 — 새 VM 을 만들지 않는다는 사용자 방침):
#   path[0] c → 1단 .88:443  (multi-fec-relay,   /usr/sbin)  → 2단 .88:4443  (mfx-r2a, /opt/mfx) ─┐
#   path[1] c → 1단 .117:443 (multi-fec-relay-b, /usr/sbin)  → 2단 .117:4443 (mfx-r2b, /opt/mfx) ─┴→ s .102:443
#   1단 유닛은 drop-in `xver2-route.conf` 로 --route 전환, 2단은 임시 유닛 `mfx-r2{a,b}`. 전부 --sock-buf 4096.
#
# 전제(사전 배치): c·s·r 의 /usr/sbin/multi-fec-dist.v1.3.1 · .v1.3.5 · .bak-v1.3.4
#   COMBOS="Y0:131:131:131:131 ..."  (이름:c:1단:2단:s)
# 교체 순서는 서비스 적용 순서와 같게 s → 2단 → 1단 → c.
# 판정: 터널 ping 60초 안 통과 + `ss` 로 1단 upstream→:4443, 2단 upstream→.102:443 이 실제로 있어야 부하를 건다.
# 정리(1.3.4·1단 구성 복구)는 이 스크립트가 하지 않는다.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
COMBOS=${COMBOS:-"Y0:131:131:131:131 Y1:131:131:131:135 Y2:131:131:135:135 Y3:131:135:135:135 Y4:135:135:135:135 Y5:131:135:131:131 Y6:135:131:135:131"}
STEPS=${STEPS:-"10 20"}; DUR=${DUR:-120}
OUT=raw/xver2; mkdir -p "$OUT"
SUM=$OUT/summary.txt

ver() { echo "1.3.${1:2}"; }
snap() { for p in "c $C" "r $R" "s $S"; do set -- $p
  echo "$1 $(ssh "$2" 'nstat -az UdpRcvbufErrors | tail -1' | awk '{print $2}')"; done; }

echo "# $(date '+%F %T') STEPS=$STEPS DUR=$DUR" >> "$SUM"
for combo in $COMBOS; do
  IFS=: read -r X VC V1 V2 VS <<< "$combo"
  D=$OUT/$X; mkdir -p "$D"
  T0=$(date +%s)
  echo "[$(date +%T)] ===== $X  c=$VC 1단=$V1 2단=$V2 s=$VS"
  ssh "$S" "install -m 755 /usr/sbin/multi-fec-dist.v$(ver $VS) /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server"
  ssh "$R" "install -m 755 /usr/sbin/multi-fec-dist.v$(ver $V2) /opt/mfx/multi-fec-dist && systemctl restart mfx-r2a mfx-r2b"
  ssh "$R" "install -m 755 /usr/sbin/multi-fec-dist.v$(ver $V1) /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b"
  ssh "$C" "install -m 755 /usr/sbin/multi-fec-dist.v$(ver $VC) /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client"
  {
    echo "c  $(ssh "$C" '/usr/sbin/multi-fec-dist --version | head -1; md5sum /usr/sbin/multi-fec-dist | cut -c1-8' | tr '\n' ' ')"
    echo "r1 $(ssh "$R" '/usr/sbin/multi-fec-dist --version | head -1; md5sum /usr/sbin/multi-fec-dist | cut -c1-8' | tr '\n' ' ')"
    echo "r2 $(ssh "$R" '/opt/mfx/multi-fec-dist --version | head -1; md5sum /opt/mfx/multi-fec-dist | cut -c1-8' | tr '\n' ' ')"
    echo "s  $(ssh "$S" '/usr/sbin/multi-fec-dist --version | head -1; md5sum /usr/sbin/multi-fec-dist | cut -c1-8' | tr '\n' ' ')"
  } > "$D/versions.txt"

  ok=0
  for i in $(seq 1 12); do
    ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1' > "$D/ping.txt" 2>&1 && { ok=1; break; }
    sleep 5
  done
  # 2단 경유 확인: 1단 upstream → :4443 2개, 2단 upstream → .102:443 2개
  ssh "$R" 'ss -uanp | grep multi-fec' > "$D/ss_r.txt" 2>&1
  n1=$(awk '$5 ~ /:4443$/' "$D/ss_r.txt" | wc -l)
  n2=$(awk '$5 ~ /^192\.168\.100\.102:443$/' "$D/ss_r.txt" | wc -l)
  if [ $ok -ne 1 ] || [ "$n1" -lt 2 ] || [ "$n2" -lt 2 ]; then
    echo "[$(date +%T)] $X FAIL: ping=$ok 1단→2단=$n1 2단→서버=$n2 — 부하 생략"
    echo "$X c=$VC r1=$V1 r2=$V2 s=$VS FAIL ping=$ok hop1=$n1 hop2=$n2" >> "$SUM"
  else
    snap > "$D/nstat_before.txt"
    RUNID=x2_$X STEPS="$STEPS" DUR=$DUR ./run_load.sh > "$D/run.out" 2>&1
    rc=$?
    snap > "$D/nstat_after.txt"
    res=$(grep -E '^\[run\] +[0-9]+ Mbps' "$D/run.out" | awk '{printf "%s:up%s/dn%s ", $2, $5, $9}')
    drops=$(paste "$D/nstat_before.txt" "$D/nstat_after.txt" | awk '{printf "%s+%d ", $1, $4-$2}')
    echo "[$(date +%T)] $X rc=$rc hop1=$n1 hop2=$n2  $res  drop $drops"
    echo "$X c=$VC r1=$V1 r2=$V2 s=$VS rc=$rc hop1=$n1 hop2=$n2 $res drop $drops" >> "$SUM"
  fi
  for p in "c $C multi-fec-client" "r1 $R multi-fec-relay -u multi-fec-relay-b" "r2 $R mfx-r2a -u mfx-r2b" "s $S multi-fec-server"; do
    set -- $p; n=$1; h=$2; shift 2
    ssh "$h" "journalctl -u $* --since @$T0 --no-pager" > "$D/log_$n.txt" 2>&1
  done
  echo "  warn/err c=$(grep -cE 'WARN|ERROR|FATAL' "$D/log_c.txt") r1=$(grep -cE 'WARN|ERROR|FATAL' "$D/log_r1.txt") r2=$(grep -cE 'WARN|ERROR|FATAL' "$D/log_r2.txt") s=$(grep -cE 'WARN|ERROR|FATAL' "$D/log_s.txt")" \
       "  path lines: $(grep -oE 'path\[[01]\] [A-Z]+' "$D/log_c.txt" | sort | uniq -c | tr -s ' ' | tr '\n' ';')" | tee -a "$SUM"
  if [ -f "$D/run.out" ] && grep -qE '트립|소멸|기동 실패' "$D/run.out"; then
    echo "[$(date +%T)] 가드 트립/실패 — 중단"; echo "$X GUARD STOP" >> "$SUM"; exit 4
  fi
done
echo "[$(date +%T)] 완료"
