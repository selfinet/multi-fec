#!/bin/bash
# mf_soak.sh — multi-fec 장시간 소크 (누수·FD·경로 진동 확인)
#
# 계단(mf_ladder3.sh)이 성능 프로파일을 보는 것과 달리, 이쪽은 고정 레이트로
# 오래 돌려 시간에 비례해 쌓이는 문제를 본다:
#   RSS 누수 / FD 누수 / 경로 상태 진동 / 전달률 시간열화
#
# iperf3 를 한 번에 5시간 돌리지 않고 CHUNK 단위로 쪼갠다. 한 번 죽어도 전체를
# 잃지 않고, 청크별 전달률을 시계열로 남겨 "뒤로 갈수록 나빠지는지"를 본다.
#
# 사용: mf_soak.sh <Mbps> [총초] [청크초]
set -u

RATE=${1:?사용법: mf_soak.sh <Mbps> [총초=18000] [청크초=1800]}
TOTAL=${2:-18000}
CHUNK=${3:-1800}

D=${D:-/tmp/mfsoak}
S=${S:-10.9.10.1}
IF=${IF:-enp2s0}
LIMIT=${LIMIT:-6000000}      # B/s = 48 Mbps (gw 대리지표 TX+RX)
WIN=${WIN:-5}
PORT=${PORT:-5201}

mkdir -p "$D"
: > "$D/timeline.log"; : > "$D/rate.csv"; : > "$D/trip"; : > "$D/chunks.csv"
echo "ts,phase,tx_Bps,rx_Bps,gw_Bps" > "$D/rate.csv"
echo "chunk,ts_start,sent,lost,loss_pct,ooo,rc" > "$D/chunks.csv"
echo running > "$D/phase"

log(){ echo "$(date +%s) $*" | tee -a "$D/timeline.log"; }
ifctr(){ awk -v i="$IF:" '$1==i{print $2, $10}' /proc/net/dev; }

( while true; do
    p=$(cat "$D/phase" 2>/dev/null || echo "?"); t0=$(date +%s)
    read -r rx0 tx0 <<< "$(ifctr)"; sleep "$WIN"
    read -r rx1 tx1 <<< "$(ifctr)"
    r=$(( (tx1-tx0)/WIN )); x=$(( (rx1-rx0)/WIN )); tot=$(( r+x ))
    echo "$t0,$p,$r,$x,$tot" >> "$D/rate.csv"
    if [ "$tot" -gt "$LIMIT" ]; then
        log "WATCHDOG gw=${tot}B/s > ${LIMIT} -> KILL"; echo "$p $tot" >> "$D/trip"
        pkill -f 'ipe[r]f3 -c'
    fi
  done ) & WD=$!
ping -D -i 1 -O "$S" > "$D/ping.log" 2>&1 & PG=$!
trap 'kill $WD $PG 2>/dev/null; echo DONE > "$D/phase"' EXIT

log "SOAK start  rate=${RATE}Mbps 양방향  total=${TOTAL}s  chunk=${CHUNK}s  limit=$(( LIMIT*8/1000000 ))Mbps"

END=$(( $(date +%s) + TOTAL )); n=0
while [ "$(date +%s)" -lt "$END" ]; do
    n=$(( n + 1 )); ts=$(date +%s)
    left=$(( END - ts )); [ "$left" -lt "$CHUNK" ] && CHUNK=$left
    [ "$CHUNK" -lt 60 ] && break
    echo "chunk$n" > "$D/phase"
    timeout $(( CHUNK + 30 )) iperf3 -c "$S" -p "$PORT" -u --bidir \
        -b "${RATE}M" -l 1200 -t "$CHUNK" -i 0 > "$D/iperf_c$n.log" 2>&1
    rc=$?
    # 상향(TX-C, [5]) = 신뢰 가능한 방향. receiver 줄에서 손실을 읽는다.
    read -r sent lost pct <<< "$(awk '/\[  5\]/ && /receiver/ {
        split($(NF-2), a, "/"); gsub(/[()%]/,"",$(NF-1));
        print a[2], a[1], $(NF-1); exit }' "$D/iperf_c$n.log")"
    ooo=$(awk '/out-of-order/{print $(NF-3); exit}' "$D/iperf_c$n.log")
    echo "$n,$ts,${sent:-0},${lost:-0},${pct:-NA},${ooo:-0},$rc" >> "$D/chunks.csv"
    log "chunk$n 완료  sent=${sent:-?} lost=${lost:-?} (${pct:-?}%) ooo=${ooo:-?} rc=$rc  남은=$(( END - $(date +%s) ))s"
    sleep 5
done

echo DONE > "$D/phase"; log "SOAK 완료 (청크 $n개)"
