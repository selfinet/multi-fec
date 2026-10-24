#!/bin/bash
# run.sh — failover 비교: 1.4.1-v5 vs 1.4.0 × 활성 경로 r(path 손실 5%) / rs2(2%) (2026-10-24, 테스트망 전용)
#
# 왜: 10-23 3모드 시험의 failover 는 손실 5% 경로가 활성이었고 1.4.0 비교가 없었다.
#   ① 같은 조건에서 1.4.0 과 비교  ② 손실 낮은 경로를 활성으로 두면 손실이 주는지.
# 조건마다: 계단 10·20·30·40 Mbps(60초) + 15 Mbps 절단(cut1 = rs2, cut0 = r) 1회. 회차마다 버전을 번갈아 시간대 편향을 줄인다.
#   활성 경로는 client.conf 의 path 순서로 정한다(failover pref = path 순서).
# 작업: 시험 동안만 c·s multipath-mode = failover, c path 순서 바꿈(원본 *.bak-failover-2026-10-24), 바이너리 교체·재시작
# 영향: 테스트망 터널이 교체·재시작마다 1초 안팎 끊김
# 되돌리기: 끝나면(중단돼도) 원본 conf 복원 + 4대 .v1.4.0 — 시작 전과 같은 상태
#
#   REPS=2 ./run.sh
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; R2=root@192.168.100.131; S=root@192.168.100.102
REPS=${REPS:-2}; RATES=${RATES:-"10 20 30 40"}; BAK=bak-failover-2026-10-24
inst() { ssh "$1" "install -m 755 /usr/sbin/multi-fec-dist.v$3 /usr/sbin/multi-fec-dist && systemctl restart $2"; }
setall() { inst $S multi-fec@server $1; inst $R multi-fec@relay $1; inst $R2 multi-fec@relay $1; inst $C multi-fec@client $1
  for i in $(seq 1 12); do ssh $C 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done; sleep 15; }

# 원본 백업(한 번만) 후 failover · 활성 경로 지정
prep() {
  for h in "$C client" "$S server"; do set -- $h
    ssh $1 "f=/etc/multi-fec/instances/$2.conf; [ -f \$f.$BAK ] || cp -p \$f \$f.$BAK; sed -i 's/^multipath-mode = .*/multipath-mode = failover/' \$f"; done
}
setactive() {   # $1 = r | rs2 — 그 경로를 첫 path 줄로
  local first second
  if [ "$1" = r ]; then first=192.168.100.88; second=192.168.100.131; else first=192.168.100.131; second=192.168.100.88; fi
  ssh $C "f=/etc/multi-fec/instances/client.conf
    grep -v '^path = ' \$f.$BAK | sed 's/^multipath-mode = .*/multipath-mode = failover/' > \$f.tmp
    awk -v a='path = 0.0.0.0:$first:443' -v b='path = 0.0.0.0:$second:443' '!d && /^multipath-mode/ {print a; print b; d=1} {print}' \$f.tmp > \$f
    rm -f \$f.tmp; chmod 600 \$f; grep -nE '^(path|multipath)' \$f | tr '\n' ' '"
}
fin() {
  echo "[$(date +%T)] ===== 정리 · 원본 conf 복원 · 1.4.0"
  for h in "$C client" "$S server"; do set -- $h
    ssh $1 "f=/etc/multi-fec/instances/$2.conf; [ -f \$f.$BAK ] && cp -p \$f.$BAK \$f; grep -nE '^(path|multipath)' \$f | tr '\n' ' '; echo"; done
  setall 1.4.0
  for h in $C $R $R2 $S; do ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@server 2>/dev/null | tr "\n" " ")"'; done
  ssh $C 'ping -c 5 -i 0.3 -W 1 -q 10.9.20.1 | tail -1'
  echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist | cut -c1-8)"
}
trap fin EXIT

prep
for rep in $(seq 1 $REPS); do
 for act in r rs2; do
  for v in 1.4.1-v5 1.4.0; do
    [ $((rep % 2)) -eq 0 ] && v=$([ "$v" = 1.4.0 ] && echo 1.4.1-v5 || echo 1.4.0)   # 짝수 회차는 순서를 뒤집는다
    tag=${act}_v${v//./}_$rep
    echo "[$(date +%T)] ##### rep$rep active=$act v$v  $(setactive $act)"
    setall $v
    ssh $C "journalctl -u multi-fec@client --since '-40s' --no-pager | grep -o 'client mode started (multipath=[a-z-]*)' | tail -1"
    for r in $RATES; do
      out=$(RUNID=st_${tag}_$r RATES=$r REPS=1 DUR=60 GAP=1 SCEN=steady ./tunnel_regress.sh 2>&1)
      echo "$out" | grep -E '^\[run\] steady|트립|기동 실패' | sed "s/^/  [$tag] /"
      echo "$out" | grep -q '트립\|기동 실패' && { echo "  [$tag] $r Mbps 에서 중단"; break; }
    done
    out=$(RUNID=cut_$tag RATES=15 REPS=1 DUR=60 CUT_AT=20 UP_AT=45 GAP=3 SCEN="cut1 cut0" ./tunnel_regress.sh 2>&1)
    echo "$out" | grep -E '^\[run\] cut|트립|기동 실패' | sed "s/^/  [$tag] /"
  done
 done
done
echo "[$(date +%T)] FAILOVER_DONE"
