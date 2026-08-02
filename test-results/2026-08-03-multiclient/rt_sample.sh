#!/bin/bash
# 병렬 체인 프로세스의 CPU/RSS/FD 를 기록. comm 검사로 샘플러 자신을 제외한다.
PAT="$1"; OUT="$2"; SECS="${3:-3600}"
echo "t,nproc,rss_kb,fd,cpu_pct,sys_busy_pct" > $OUT
prev_p=0; prev_s=0; prev_i=0; first=1
end=$(( $(date +%s) + SECS ))
while [ $(date +%s) -lt $end ]; do
  rss=0; ticks=0; n=0; fds=0
  for p in $(pgrep -f "$PAT" 2>/dev/null); do
    [ "$(cat /proc/$p/comm 2>/dev/null)" = "multi-fec-dist" ] || continue
    r=$(awk '/VmRSS/{print $2}' /proc/$p/status 2>/dev/null); [ -z "$r" ] && continue
    u=$(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null); [ -z "$u" ] && continue
    f=$(ls /proc/$p/fd 2>/dev/null | wc -l)
    rss=$((rss+r)); ticks=$((ticks+u)); n=$((n+1)); fds=$((fds+f))
  done
  [ $n -eq 0 ] && { sleep 10; continue; }
  read -r _ a b c d rest < /proc/stat; idle=$d; tot=$((a+b+c+d))
  if [ $first -eq 0 ]; then
    awk -v t=$(date +%s) -v n=$n -v r=$rss -v fd=$fds -v dp=$((ticks-prev_p)) \
        -v dt=$((tot-prev_s)) -v di=$((idle-prev_i)) \
      'BEGIN{printf "%d,%d,%d,%d,%.1f,%.1f\n", t,n,r,fd,(dp*100.0/10/100),(dt>0?(dt-di)*100.0/dt:0)}' >> $OUT
  fi
  prev_p=$ticks; prev_s=$tot; prev_i=$idle; first=0
  sleep 10
done
#
