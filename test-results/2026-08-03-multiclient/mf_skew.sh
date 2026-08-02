#!/bin/bash
# mf_skew.sh — 경로 지연차별 재정렬 측정 (테스트망 전용)
#
# 왜: duplicate 2경로에서 지연차 × pps 만큼 변위가 생긴다. 현재 테스트망은 편도 지연차
#     5ms 라 변위 2.43 이었다. 국제 구간(RTT 250/180ms)으로 올리면 얼마가 되는지,
#     그리고 그게 TCP 에 실제로 해를 끼치는지 본다.
# 방향: netem 은 c egress(상향) + r egress(하향) 에 걸려 있다. UDP 재정렬은 c→s 단방향.
# 안전: gw 50Mbps. 단방향 6Mbps → 회선 약 17.5Mbps(FEC 1.29 × dup 2 × 패딩 1.13). 각 구간 실측 보고.
set -u
C=c.xdn.selfinet.com; R=r.xdn.selfinet.com; S=s.xdn.selfinet.com
D=/tmp/claude-1000/-home-stevekim-multi-fec/09ddbccc-f6ab-4626-ba7c-12c7dc973215/scratchpad/skew
mkdir -p $D
UDP_SECS=${UDP_SECS:-60}; TCP_SECS=${TCP_SECS:-30}; MBPS=${MBPS:-6}
ORIG0=25ms; ORIG1=30ms

restore() {
  echo; echo "[$(date +%H:%M:%S)] netem 원복 → $ORIG0 / $ORIG1"
  for h in $C $R; do
    ssh $h "sudo sed -i 's/^P0_DELAY=.*/P0_DELAY=$ORIG0/; s/^P1_DELAY=.*/P1_DELAY=$ORIG1/' /etc/multi-fec/netem.conf && sudo systemctl restart mf-netem" 2>/dev/null
  done
  ssh $S 'sudo pkill -f "mf_reorder.py recv"; pkill -f "iperf[3] -s"' 2>/dev/null
  for h in $C $R; do printf "  %s: " ${h%%.*}; ssh $h 'tc qdisc show 2>/dev/null | grep -oE "delay [0-9]+ms loss [0-9]+%" | tr "\n" " "' 2>/dev/null; echo; done
}
trap restore EXIT INT TERM

apply() {  # <편도0> <편도1>
  for h in $C $R; do
    ssh $h "sudo sed -i 's/^P0_DELAY=.*/P0_DELAY=$1/; s/^P1_DELAY=.*/P1_DELAY=$2/' /etc/multi-fec/netem.conf && sudo systemctl restart mf-netem" 2>/dev/null
  done
}
ifc() { ssh $C 'awk -v i="enp2s0:" "\$1==i{print \$2+\$10}" /proc/net/dev' 2>/dev/null; }

echo "cond,delay0,delay1,skew_ms,rtt_ms,recv,lost,loss_pct,reord,reord_pct,disp_avg,disp_max,gw_Mbps,tcp_Mbps,tcp_retr" > $D/result.csv

run() {  # <라벨> <편도0> <편도1> <설명>
  local cond=$1 d0=$2 d1=$3 desc=$4
  local skew=$(( ${d1%ms} > ${d0%ms} ? ${d1%ms}-${d0%ms} : ${d0%ms}-${d1%ms} ))
  echo; echo "=================================================================="
  echo "[$(date +%H:%M:%S)] $cond — $desc   (편도 $d0 / $d1, 지연차 ${skew}ms)"
  apply $d0 $d1
  echo "  경로 안정화 대기 25s..."; sleep 25
  local rtt=$(ssh $C "ping -c5 -i0.3 -W3 10.9.10.1 2>/dev/null | awk -F/ '/rtt/{print \$5}'" 2>/dev/null)
  echo "  터널 RTT ${rtt}ms"

  # --- UDP 단방향 재정렬 ---
  ssh $S "nohup /tmp/mf_reorder.py recv --bind 10.9.10.1:5301 --timeout 15 --json > /tmp/reo_$cond.json 2>&1 &" 2>/dev/null
  sleep 2
  local g0=$(ifc)
  ssh $C "/tmp/mf_reorder.py send --to 10.9.10.1:5301 --mbps $MBPS --secs $UDP_SECS" 2>/dev/null | sed 's/^/    /'
  local g1=$(ifc)
  sleep 6
  local j=$(ssh $S "cat /tmp/reo_$cond.json" 2>/dev/null)
  local gw=$(awk -v a=$g0 -v b=$g1 -v s=$UDP_SECS 'BEGIN{printf "%.2f",(b-a)*8/s/1e6}')
  echo "    gw 통과 ${gw} Mbps"
  echo "$j" > $D/reo_$cond.json
  echo "$j" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f\"    수신 {d['received']:,}  손실 {d['lost']} ({d['loss_pct']}%)  중복 {d['dup']}\")
print(f\"    재정렬 {d['reordered_late']:,} ({d['reordered_pct']}%)   변위 평균 {d['displacement_avg']} / 최대 {d['displacement_max']}\")"

  # --- TCP 영향 ---
  ssh $S 'nohup iperf3 -s -1 -p 5202 >/dev/null 2>&1 &' 2>/dev/null; sleep 2
  ssh $C "iperf3 -c 10.9.10.1 -p 5202 -t $TCP_SECS -i 0 --fq-rate 8M -J" 2>/dev/null > $D/tcp_$cond.json
  local tcp=$(python3 -c "
import json;d=json.load(open('$D/tcp_$cond.json'))
e=d['end']['sum_sent'];print(f\"{e['bits_per_second']/1e6:.2f} {e.get('retransmits',0)}\")" 2>/dev/null || echo "NA NA")
  echo "    TCP $(echo $tcp | cut -d' ' -f1) Mbps, 재전송 $(echo $tcp | cut -d' ' -f2)"

  echo "$j" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(f\"$cond,$d0,$d1,$skew,${rtt:-NA},{d['received']},{d['lost']},{d['loss_pct']},{d['reordered_late']},{d['reordered_pct']},{d['displacement_avg']},{d['displacement_max']},$gw,$(echo $tcp|tr ' ' ',')\")" >> $D/result.csv
}

run A 25ms  30ms  "현재 테스트망 (RTT 50/60)"
run B 125ms 90ms  "국제: RTT 250/180"
run C 250ms 180ms "비관: 편도 250/180 (RTT 500/360)"

echo; echo "=================== 결과 ==================="; column -t -s, $D/result.csv
