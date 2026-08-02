#!/bin/bash
# sv1 에서 실행. c/s 의 FIFO 를 driving 하며 FEC 강도 A/B.
#
# 확인된 보간 테이블 (g=7 기준, 6Mbps/t10):
#   5:1,20:4 → y=2 (28.6%)   ← 현재
#   5:1,20:2 → y=2 (28.6%)   ← 차이 없음. 보간이 올림이라 절감 안 됨
#   10:1,20:2 → y=1 (14.3%)  ← 작은 그룹만 아끼고 큰 그룹은 y=2 유지
set -u
C=c.xdn.selfinet.com; S=s.xdn.selfinet.com
SECS=${SECS:-600}; MBPS=${MBPS:-6}
D=/tmp/claude-1000/-home-stevekim/fecab; mkdir -p $D
echo "cfg,fec,orig_pkt,fec_pkt,amp,gw_Mbps,sent,lost,loss_pct" > $D/result.csv

cnt() { ssh $C 'sudo journalctl -u multi-fec-client --since "-90s" --no-pager 2>/dev/null |
  grep -oE "client-->server:\(original:[0-9]+ pkt[^)]*\) \(fec:[0-9]+ pkt" | tail -1 |
  grep -oE "[0-9]+" | tr "\n" " " | awk "{print \$1, \$3}"' 2>/dev/null; }
ifc() { ssh $C 'awk -v i="enp2s0:" "\$1==i{print \$2, \$10}" /proc/net/dev' 2>/dev/null; }

run() {  # <라벨> <fec>
  local cfg=$1 fec=$2
  echo "[$(date +%H:%M:%S)] $cfg  -f $fec  (${SECS}s)"
  ssh $C "echo 'fec $fec' | sudo tee /run/multi-fec/client.fifo >/dev/null" 2>/dev/null
  ssh $S "echo 'fec $fec' | sudo tee /run/multi-fec/server.fifo >/dev/null" 2>/dev/null
  sleep 25

  read -r o0 f0 <<< "$(cnt)"; read -r rx0 tx0 <<< "$(ifc)"
  ssh $C "iperf3 -c 10.9.10.1 -p 5201 -u --bidir -b ${MBPS}M -l 1200 -t $SECS -i 0" \
      > $D/ip_$cfg.log 2>&1
  read -r rx1 tx1 <<< "$(ifc)"
  sleep 70
  read -r o1 f1 <<< "$(cnt)"

  local do_=$(( o1 - o0 )) df=$(( f1 - f0 ))
  local amp=$(awk -v o=$do_ -v f=$df 'BEGIN{if(o>0)printf "%.4f",f/o; else print "NA"}')
  local gw=$(awk -v a=$((tx1-tx0)) -v b=$((rx1-rx0)) -v s=$SECS 'BEGIN{printf "%.2f",(a+b)*8/s/1e6}')
  read -r sent lost pct <<< "$(awk '/\[  5\]/ && /receiver/ {
      split($(NF-2),a,"/"); gsub(/[()%]/,"",$(NF-1)); print a[2],a[1],$(NF-1); exit}' $D/ip_$cfg.log)"

  echo "$cfg,$fec,$do_,$df,$amp,$gw,${sent:-0},${lost:-0},${pct:-NA}" >> $D/result.csv
  printf "   FEC증폭 %s  gw %s Mbps  손실 %s/%s (%s%%)\n" "$amp" "$gw" "${lost:-?}" "${sent:-?}" "${pct:-?}"
}

run A "5:1,20:4"
run B "10:1,20:2"
run C "5:1,20:4"        # 원복 + 재현성

echo; echo "=== 결과 ==="; cat $D/result.csv
