#!/bin/bash
# mf_ladder3.sh — c.xdn 부하 계단 v3 (gw 상한 50 Mbps)
#
# ── gw 대리지표 (v2 대비 변경) ────────────────────────────────────────
#   토폴로지가 "양쪽 다 릴레이 경유"로 바뀌면서 c→r 이 같은 /24 온링크가 되어
#   gw 를 타지 않는다. v2 의 "c:enp2s0 TX = gw 상향" 전제가 무효다.
#   이제 gw 를 지나는 것은 r↔s 구간뿐이고, 릴레이는 1:1 포워딩이므로
#
#       gw 상향  = r→s = c 가 보낸 것         = c TX
#       gw 하향  = s→r = c 가 받은 것 / (1-손실) ≈ c RX / 0.965
#
#   따라서 대리지표는 TX+RX 합이고, 하향의 netem 보정분(최대 3.5%)만큼
#   과소평가되므로 상한을 50 이 아니라 48 Mbps 로 잡아 여유를 둔다.
#
# ── 2026-08-02 수정: 하네스 결함 2건 (REPORT.md §2-2) ─────────────────
#   1) 트립 라벨 지연 — 워치독이 창 '시작' 시점 phase 로 라벨을 붙였는데
#      킬은 창 '끝' 시점에 도는 프로세스에 적용된다. 구간 전환 직후 트립하면
#      이전 구간 이름으로 기록되고 현재 구간은 "트립 안 함"으로 보였다.
#      → 창 시작/끝 phase 를 모두 기록하고, **트립은 끝 시점 phase 로** 남긴다.
#        요약 통계는 두 값이 같은 '순수 창'만 집계해 경계 오염을 배제한다.
#   2) rc 미확인 — 완주 판정을 트립 파일로만 해서, 4.4초 만에 죽은 구간이
#      완주로 집계됐다(요약이 "최고 완주 10 Mbps" 로 오판, 실제는 8).
#      → rc==0 && 트립 없음 && 실제 경과시간 >= 요청의 90% 를 모두 요구한다.
#        rc 만으로는 부족하다 — 조기 종료해도 iperf3 가 0 을 반환하는 경우가 있다.
#
#   txrate.csv 포맷이 바뀌었다: ts,phase_start,phase_end,tx,rx,gw  (v3 이전은 5열)
#
# ── 2026-08-02 추가 수정: gw 허용치 초과 재발 방지 (REPORT.md §2-2) ───
#   실측 중 u12M 에서 5초 창 하나가 58.07 Mbps 로 허용치 50 을 넘겼다.
#   워치독은 창이 끝난 뒤 판정하므로 **첫 초과 창은 구조적으로 못 막는다** —
#   "초과를 막는 장치"가 아니라 "초과가 지속되는 걸 막는 장치"다.
#   따라서 초과를 막으려면 애초에 넘길 구간을 실행하지 않아야 한다.
#
#   1) 예측 기반 차단: 직전 완주 구간에서 증폭(gw최대 ÷ 앱총량)을 실측하고,
#      다음 구간의 gw 부하를 예측해 LIMIT 을 넘을 것 같으면 실행하지 않는다.
#      실측 데이터로 검산: u6M 실측 증폭 2.96 → u8M 예측 47.4 < 48 (실행, 실제 44.45)
#                        u8M 실측 증폭 2.78 → u10M 예측 55.6 > 48 (차단)
#      → 48.39 도, 58.07 도 애초에 발생하지 않는다.
#   2) 워치독 창 5초 → 1초: 예측이 빗나가도 노출과 초과분 적분이 1/5 로 준다.
#   3) 3중 안전 마진 — 사용자 허용치 50 Mbps 를 어떤 경우에도 넘지 않도록:
#        50 Mbps  사용자 허용치 (실제 gw)
#        48 Mbps  LIMIT  = 워치독 즉시 킬. 대리지표가 하향을 최대 3.5% 과소평가
#                 하므로 50/1.035 ≈ 48.3 에서 내림
#        42 Mbps  GATE   = LIMIT x SAFETY(88%). 예측 판단은 여기서 한다.
#                 증폭이 톱니(실측 2.66~3.02)라 직전 실측 대비 최대 +13.5% 튈 수
#                 있으므로 42 x 1.135 = 47.7 < 48 로 흡수된다
#      게이트를 낮추면 정밀도가 떨어지므로, 다음 고정 스텝이 게이트를 넘으면
#      **게이트에 맞는 최대 레이트로 한 번 더 시도**해 한계를 좁힌다(스텝 피팅).
set -u

D=${D:-/tmp/mftest3}
S=${S:-10.9.10.1}
IF=${IF:-enp2s0}
LIMIT=${LIMIT:-6000000}         # B/s = 48 Mbps (gw 허용 50 에 4% 여유)
WIN=${WIN:-1}                   # 워치독 창(초). 1 = 초과 노출 최소화
DUR=${DUR:-120}
TCP_DUR=${TCP_DUR:-120}
UDP_PORT=${UDP_PORT:-5201}
TCP_PORT=${TCP_PORT:-5202}
STEPS=${STEPS:-"2 4 6 8 10 12"}   # Mbps, 양방향 각각
MIN_FRAC=${MIN_FRAC:-90}          # 완주로 인정할 최소 경과시간 비율 (%)
AMP_INIT=${AMP_INIT:-3.2}         # 실측 전 증폭 추정치(관측 최대 3.02 에 여유)
SAFETY=${SAFETY:-88}              # 예측 게이트 = LIMIT 의 % (톱니 오차 흡수)

mkdir -p "$D"
: > "$D/timeline.log"; : > "$D/trip"; : > "$D/summary.txt"
echo "ts,phase_start,phase_end,tx_Bps,rx_Bps,gw_Bps" > "$D/txrate.csv"
echo init > "$D/phase"

log(){ echo "$(date +%s) $*" | tee -a "$D/timeline.log"; }
ifctr(){ awk -v i="$IF:" '$1==i{print $2, $10}' /proc/net/dev; }   # rx tx
tripped(){ grep -q "^$1 " "$D/trip" 2>/dev/null; }

# ── 워치독 ────────────────────────────────────────────────────────────
(
  while true; do
    p0=$(cat "$D/phase" 2>/dev/null || echo "?"); t0=$(date +%s)
    read -r rx0 tx0 <<< "$(ifctr)"
    sleep "$WIN"
    read -r rx1 tx1 <<< "$(ifctr)"
    p1=$(cat "$D/phase" 2>/dev/null || echo "?")     # 창 끝 = 킬 대상
    r=$(( (tx1 - tx0) / WIN )); x=$(( (rx1 - rx0) / WIN )); tot=$(( r + x ))
    echo "$t0,$p0,$p1,$r,$x,$tot" >> "$D/txrate.csv"
    if [ "$tot" -gt "$LIMIT" ]; then
        log "WATCHDOG gw=${tot}B/s (tx=$r rx=$x) > ${LIMIT}  창=[$p0→$p1] KILL대상=$p1"
        echo "$p1 $tot" >> "$D/trip"
        pkill -f 'ipe[r]f3 -c'
    fi
  done
) & WD=$!
ping -D -i 0.5 -O "$S" > "$D/ping.log" 2>&1 & PG=$!
trap 'kill $WD $PG 2>/dev/null; echo DONE > "$D/phase"' EXIT

# iperf3 로그의 sender 줄에서 실제 경과 초를 읽는다.
#   [  5][TX-C]   0.00-120.00 sec  ...  sender     → 120.00
# 조기 종료해도 이 값은 정직하므로 rc 보다 신뢰할 수 있다.
elapsed_of(){
  awk '/sender/ && /\[  5\]/ { split($3, a, "-"); printf "%.0f", a[2]; exit }' "$1" 2>/dev/null
}

# 완주 판정: rc==0 && 트립 없음 && 경과 >= 요청의 MIN_FRAC%
phase_ok(){  # <label> <요청초> <rc>
  local label=$1 want=$2 rc=$3 got need
  got=$(elapsed_of "$D/iperf_$label.log"); got=${got:-0}
  need=$(( want * MIN_FRAC / 100 ))
  if [ "$rc" -ne 0 ];         then log "  ✗ $label 미완주: rc=$rc";            return 1; fi
  if tripped "$label";        then log "  ✗ $label 미완주: 워치독 트립";        return 1; fi
  if [ "$got" -lt "$need" ];  then log "  ✗ $label 미완주: ${got}s < ${need}s"; return 1; fi
  log "  ✓ $label 완주 (${got}s)"
  return 0
}

# 완주한 구간의 실측 증폭 = gw 최대 ÷ 앱 총량(양방향이라 2배).
# 경계 창은 두 구간이 섞여 있으므로 순수 창만 본다.
amp_of(){  # <phase> <Mbps>
  awk -F, -v p="$1" -v m="$2" '
    NR>1 && $2==p && $2==$3 && $6+0>mx { mx=$6 }
    END { if (m+0>0 && mx>0) printf "%.3f", mx*8/1e6/(2*m); else printf "0" }' "$D/txrate.csv"
}

udp(){  # <label> <Mbps> <dur> → 완주면 0
  echo "$1" > "$D/phase"; log "PHASE $1 start  udp bidir -b $2M ${3}s"
  timeout $(( $3 + 20 )) iperf3 -c "$S" -p "$UDP_PORT" -u --bidir \
      -b "${2}M" -l 1200 -t "$3" -i 30 > "$D/iperf_$1.log" 2>&1
  local rc=$?; log "PHASE $1 end rc=$rc"
  sleep 5                       # 워치독이 마지막 창을 기록할 시간을 준다
  phase_ok "$1" "$3" "$rc"
}
tcp(){  # <label> <bps> <dur>   fq-rate 커널 페이싱 (v2 §7-2)
  echo "$1" > "$D/phase"; log "PHASE $1 start  tcp bidir -b $2 --fq-rate $2 ${3}s"
  timeout $(( $3 + 20 )) iperf3 -c "$S" -p "$TCP_PORT" --bidir \
      -b "$2" --fq-rate "$2" -t "$3" -i 1 > "$D/iperf_$1.log" 2>&1
  local rc=$?; log "PHASE $1 end rc=$rc"
  sleep 5
  phase_ok "$1" "$3" "$rc"
}

summary(){
  {
    echo; echo "=== phase별 c:$IF (Mbps, ${WIN}초 창 / 경계 창 제외) ==="
    printf "  %-8s %-4s %8s %8s %8s %8s\n" phase n tx_avg rx_avg gw_avg gw_max
    awk -F, -v L="$LIMIT" '
      NR==1 || $2=="" || $2=="init" { next }
      # 창 시작·끝 phase 가 다르면 두 구간의 바이트가 섞인 경계 창이다.
      # 어느 쪽으로 붙여도 틀리므로 통계에서 뺀다 (이게 §2-2 의 48.39 오염원).
      $2 != $3 { skipped++; next }
      {
        if (!($2 in n)) ord[++c]=$2
        n[$2]++; st[$2]+=$4; sr[$2]+=$5; sg[$2]+=$6
        if ($6>mx[$2]) mx[$2]=$6
      }
      END {
        for (i=1;i<=c;i++) { p=ord[i]
          printf "  %-8s %-4d %8.2f %8.2f %8.2f %8.2f%s\n", p, n[p],
            st[p]/n[p]*8/1e6, sr[p]/n[p]*8/1e6, sg[p]/n[p]*8/1e6, mx[p]*8/1e6,
            (mx[p]>L ? "  ** 상한 초과 **" : "")
        }
        printf "  %-8s %-4s %8s %8s   limit=%.1f\n", "", "", "", "", L*8/1e6
        printf "  (경계 창 %d개 제외)\n", skipped+0
      }' "$D/txrate.csv"
    echo; echo "=== 워치독 트립 (킬 대상 phase 기준) ==="
    [ -s "$D/trip" ] && awk '{printf "  %-8s %.2f Mbps\n",$1,$2*8/1e6}' "$D/trip" || echo "  없음"
    echo; echo "=== 구간 완주 판정 ==="
    grep -E "^[0-9]+   [✓✗]" "$D/timeline.log" | sed 's/^[0-9]*//' || \
      grep -E "[✓✗]" "$D/timeline.log" | sed 's/^[0-9]* //'
    echo; echo "=== UDP 전달 (상향 = 신뢰 방향) ==="
    for f in "$D"/iperf_u*.log; do [ -e "$f" ] || continue
      printf "  %-16s %s\n" "$(basename "$f" .log)" \
        "$(awk '/sender/ && /\[  5\]/ {print $(NF-2), $(NF-1); exit}' "$f")"
    done
    echo; echo "원시데이터: $D/"
  } | tee -a "$D/summary.txt"
}

GATE=$(( LIMIT * SAFETY / 100 ))
log "RUN start  LIMIT=$(( LIMIT*8/1000000 ))Mbps(킬) GATE=$(( GATE*8/1000000 ))Mbps(예측차단) WIN=${WIN}s DUR=${DUR}s STEPS=[$STEPS]"
LAST_OK=0
AMP=$AMP_INIT                                  # 첫 구간은 실측이 없으니 보수적 추정으로 시작
for m in $STEPS; do
  # ── 예측 차단 ── 넘길 것 같으면 아예 실행하지 않는다.
  pred=$(awk -v m="$m" -v a="$AMP" 'BEGIN{printf "%.0f", 2*m*1e6/8*a}')   # B/s
  predm=$(awk -v v="$pred" 'BEGIN{printf "%.2f", v*8/1e6}')
  if [ "$pred" -gt "$GATE" ]; then
      log "u${m}M 실행 안 함 — gw 예측 ${predm}Mbps > 게이트 $(( GATE*8/1000000 ))Mbps (증폭 ${AMP}x)"
      # 스텝 피팅: 게이트 안에 들어오는 최대 정수 레이트로 한 번만 더 시도해
      # 한계를 좁힌다. 고정 스텝이 성글어 생기는 정밀도 손실을 메운다.
      mfit=$(awk -v g="$GATE" -v a="$AMP" 'BEGIN{printf "%d", int(g*8/1e6/(2*a))}')
      if [ "${mfit:-0}" -gt "$LAST_OK" ]; then
          log "  → 게이트에 맞는 u${mfit}M 로 마무리 시도"
          if udp "u${mfit}M" "$mfit" "$DUR"; then LAST_OK=$mfit; fi
      else
          log "  → 게이트 내에서 더 올릴 여지 없음"
      fi
      break
  fi
  log "u${m}M gw 예측 ${predm}Mbps (증폭 ${AMP}x) — 게이트 내, 실행"

  if udp "u${m}M" "$m" "$DUR"; then
      LAST_OK=$m
      # 실측 증폭으로 갱신. 톱니가 있어 최댓값이 아니라 '직전 실측'을 쓴다 —
      # 최댓값을 쓰면 지나치게 보수적이 되어 유효한 구간까지 건너뛴다.
      a=$(amp_of "u${m}M" "$m")
      if awk -v a="$a" 'BEGIN{exit !(a+0>0)}'; then
          log "  u${m}M 실측 증폭 ${a}x (예측에 반영)"
          AMP=$a
      fi
  else
      log "u${m}M 미완주 — 상위 구간 생략"
      break
  fi
done
log "UDP 최고 완주 구간: ${LAST_OK} Mbps"

if [ "$LAST_OK" -gt 0 ]; then
    TCAP=$(( LAST_OK * 1000000 * 7 / 10 ))     # 완주 구간의 70%
    tcp "t$(( TCAP/1000 ))k" "$TCAP" "$TCP_DUR" || log "TCP 구간 미완주"
else
    log "완주한 UDP 구간이 없어 TCP 생략"
fi

echo idle > "$D/phase"; log "PHASE idle start"; sleep 60; log "PHASE idle end"
log "ALL DONE"
summary
