#!/bin/bash
# mf_ladder3.sh — c.xdn 부하 계단 v3 (gw 상한 50 Mbps)
#
# v2 대비 바뀐 것: 워치독의 gw 대리지표
#
#   토폴로지가 "양쪽 다 릴레이 경유"로 바뀌면서 c→r 이 같은 /24 온링크가 되어
#   gw 를 타지 않는다. v2 의 "c:enp2s0 TX = gw 상향" 전제가 무효다.
#   이제 gw 를 지나는 것은 r↔s 구간뿐이고, 릴레이는 1:1 포워딩이므로
#
#       gw 상향  = r→s = c 가 보낸 것         = c TX
#       gw 하향  = s→r = c 가 받은 것 / (1-손실) ≈ c RX / 0.965
#
#   따라서 대리지표는 TX+RX 합이고, 하향의 netem 보정분(최대 3.5%)만큼
#   과소평가되므로 상한을 50 이 아니라 48 Mbps 로 잡아 여유를 둔다.
set -u

D=${D:-/tmp/mftest3}
S=${S:-10.9.10.1}
IF=${IF:-enp2s0}
LIMIT=${LIMIT:-6000000}         # B/s = 48 Mbps (gw 허용 50 에 4% 여유)
WIN=${WIN:-5}
DUR=${DUR:-120}
TCP_DUR=${TCP_DUR:-120}
UDP_PORT=${UDP_PORT:-5201}
TCP_PORT=${TCP_PORT:-5202}
STEPS=${STEPS:-"2 4 6 8 10 12"}   # Mbps, 양방향 각각

mkdir -p "$D"
: > "$D/timeline.log"; : > "$D/txrate.csv"; : > "$D/trip"; : > "$D/summary.txt"
echo init > "$D/phase"

log(){ echo "$(date +%s) $*" | tee -a "$D/timeline.log"; }
ifctr(){ awk -v i="$IF:" '$1==i{print $2, $10}' /proc/net/dev; }   # rx tx
tripped(){ grep -q "^$1 " "$D/trip" 2>/dev/null; }

# ── 워치독: TX+RX 합을 gw 대리지표로 ──────────────────────────────────
(
  while true; do
    p=$(cat "$D/phase" 2>/dev/null || echo "?"); t0=$(date +%s)
    read -r rx0 tx0 <<< "$(ifctr)"
    sleep "$WIN"
    read -r rx1 tx1 <<< "$(ifctr)"
    r=$(( (tx1 - tx0) / WIN )); x=$(( (rx1 - rx0) / WIN )); tot=$(( r + x ))
    echo "$t0,$p,$r,$x,$tot" >> "$D/txrate.csv"
    if [ "$tot" -gt "$LIMIT" ]; then
        log "WATCHDOG gw=${tot}B/s (tx=$r rx=$x) > ${LIMIT} phase=${p} -> KILL"
        echo "$p $tot" >> "$D/trip"
        pkill -f 'ipe[r]f3 -c'
    fi
  done
) & WD=$!
ping -D -i 0.5 -O "$S" > "$D/ping.log" 2>&1 & PG=$!
trap 'kill $WD $PG 2>/dev/null; echo DONE > "$D/phase"' EXIT

udp(){  # <label> <Mbps> <dur>
  echo "$1" > "$D/phase"; log "PHASE $1 start  udp bidir -b $2M ${3}s"
  timeout $(( $3 + 20 )) iperf3 -c "$S" -p "$UDP_PORT" -u --bidir \
      -b "${2}M" -l 1200 -t "$3" -i 30 > "$D/iperf_$1.log" 2>&1
  log "PHASE $1 end rc=$?"; sleep 5
}
tcp(){  # <label> <bps> <dur>   fq-rate 커널 페이싱 (v2 §7-2)
  echo "$1" > "$D/phase"; log "PHASE $1 start  tcp bidir -b $2 --fq-rate $2 ${3}s"
  timeout $(( $3 + 20 )) iperf3 -c "$S" -p "$TCP_PORT" --bidir \
      -b "$2" --fq-rate "$2" -t "$3" -i 1 > "$D/iperf_$1.log" 2>&1
  log "PHASE $1 end rc=$?"; sleep 5
}

summary(){
  {
    echo; echo "=== phase별 c:$IF (Mbps, ${WIN}초 창) ==="
    printf "  %-8s %-4s %8s %8s %8s %8s\n" phase n tx_avg rx_avg gw_avg gw_max
    awk -F, -v L="$LIMIT" '
      $2!="" && $2!="init" {
        if (!($2 in n)) ord[++c]=$2
        n[$2]++; st[$2]+=$3; sr[$2]+=$4; sg[$2]+=$5
        if ($5>mx[$2]) mx[$2]=$5
      }
      END { for (i=1;i<=c;i++) { p=ord[i]
        printf "  %-8s %-4d %8.2f %8.2f %8.2f %8.2f%s\n", p, n[p],
          st[p]/n[p]*8/1e6, sr[p]/n[p]*8/1e6, sg[p]/n[p]*8/1e6, mx[p]*8/1e6,
          (mx[p]>L ? "  ** TRIP **" : "")
      } printf "  %-8s %-4s %8s %8s limit=%.1f\n","","","","",L*8/1e6 }' "$D/txrate.csv"
    echo; echo "=== 워치독 트립 ==="
    [ -s "$D/trip" ] && awk '{printf "  %-8s %.2f Mbps\n",$1,$2*8/1e6}' "$D/trip" || echo "  없음"
    echo; echo "=== UDP 전달 (상향 = 신뢰 방향) ==="
    for f in "$D"/iperf_u*.log; do [ -e "$f" ] || continue
      printf "  %-16s %s\n" "$(basename "$f" .log)" \
        "$(awk '/sender/ && /\[  5\]/{print $(NF-2), $(NF-1); exit}' "$f")"
    done
    echo; echo "원시데이터: $D/"
  } | tee -a "$D/summary.txt"
}

log "RUN start  LIMIT=${LIMIT}B/s($(( LIMIT*8/1000000 ))Mbps) WIN=${WIN}s DUR=${DUR}s STEPS=[$STEPS]"
LAST_OK=0
for m in $STEPS; do
  udp "u${m}M" "$m" "$DUR"
  if tripped "u${m}M"; then
      log "u${m}M 에서 gw 상한 도달 — 상위 구간 생략"
      break
  fi
  LAST_OK=$m
done
log "UDP 최고 완주 구간: ${LAST_OK} Mbps"

if [ "$LAST_OK" -gt 0 ]; then
    TCAP=$(( LAST_OK * 1000000 * 7 / 10 ))     # 완주 구간의 70%
    tcp "t$(( TCAP/1000 ))k" "$TCAP" "$TCP_DUR"
fi

echo idle > "$D/phase"; log "PHASE idle start"; sleep 60; log "PHASE idle end"
log "ALL DONE"
summary
