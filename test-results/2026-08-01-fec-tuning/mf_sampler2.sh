#!/bin/bash
# sampler.sh <label> <iface> <service> <out.csv> <dur_s> <iv_s>
# 프로세스 CPU/RSS/FD + 인터페이스 TX/RX + (있으면) netem 밴드
set -u
L=$1; IF=$2; SVC=$3; OUT=$4; DUR=$5; IV=$6
END=$(( $(date +%s) + DUR ))
HZ=$(getconf CLK_TCK)
echo "ts,label,pid,cpu_pct,rss_kb,fds,if_tx_bytes,if_rx_bytes,b11_sent,b11_drop,b12_sent,b12_drop" > "$OUT"
prev_cpu=""; prev_t=""
while [ "$(date +%s)" -lt "$END" ]; do
  now=$(date +%s)
  pid=$(systemctl show -p MainPID --value "$SVC" 2>/dev/null)
  cpu=""; rss=""; fds=""
  if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -r "/proc/$pid/stat" ]; then
      st=$(awk '{print $14, $15}' /proc/$pid/stat)
      ut=${st% *}; kt=${st#* }; tot=$(( ut + kt ))
      rss=$(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null)
      fds=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
      if [ -n "$prev_cpu" ] && [ "$now" != "$prev_t" ]; then
          cpu=$(awk -v a=$tot -v b=$prev_cpu -v dt=$((now-prev_t)) -v hz=$HZ 'BEGIN{printf "%.2f",(a-b)*100.0/hz/dt}')
      fi
      prev_cpu=$tot; prev_t=$now
  fi
  tx=$(awk -v i="$IF:" '$1==i{print $10}' /proc/net/dev)
  rx=$(awk -v i="$IF:" '$1==i{print $2}'  /proc/net/dev)
  b11s=""; b11d=""; b12s=""; b12d=""
  if tc -s class show dev "$IF" >/dev/null 2>&1; then
     read b11s b11d < <(tc -s class show dev "$IF" 2>/dev/null | awk '/class prio 1:1 /{f=1;next} f&&/Sent/{gsub(/,/,"",$2); gsub(/,/,"",$7); print $2, $7; exit}')
     read b12s b12d < <(tc -s class show dev "$IF" 2>/dev/null | awk '/class prio 1:2 /{f=1;next} f&&/Sent/{gsub(/,/,"",$2); gsub(/,/,"",$7); print $2, $7; exit}')
  fi
  echo "$now,$L,$pid,$cpu,$rss,$fds,$tx,$rx,$b11s,$b11d,$b12s,$b12d" >> "$OUT"
  sleep "$IV"
done
