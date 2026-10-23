#!/bin/bash
# soak.sh — 1.4.1-v3 전 호스트 60분 소크 (2026-10-23, 테스트망 전용)
# 4대를 1.4.1 로 두고 tunnel_regress.sh steady 15 Mbps DUR=3600. 30초마다 multi-fec RSS·FD·스레드 기록(호스트별 csv).
# 끝나면(중단돼도) 4대 .v1.4.0 복원.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; R2=root@192.168.100.131; S=root@192.168.100.102
RATE=${RATE:-15}; DUR=${DUR:-3600}; V=${V:-1.4.1-v5}
inst() { ssh "$1" "install -m 755 /usr/sbin/multi-fec-dist.v$3 /usr/sbin/multi-fec-dist && systemctl restart $2"; }
HOSTS="c:$C:multi-fec@client r:$R:multi-fec@relay r2:$R2:multi-fec@relay s:$S:multi-fec@server"
restore() {
  echo "[$(date +%T)] ===== 정리 · 1.4.0 복원"
  for e in $HOSTS; do IFS=: read k h u <<<"$e"
    ssh $h "kill \$(cat /tmp/soak_res.pid) 2>/dev/null"; scp -q $h:/tmp/soak_res.csv raw/soak_res_$k.csv; ssh $h 'rm -f /tmp/soak_res.csv /tmp/soak_res.pid'
    ssh $h "journalctl -u $u --since @$T0 --no-pager -o short-unix" | sed 's/\x1b\[[0-9;]*m//g' > raw/soak_$k.log
  done
  inst $S multi-fec@server 1.4.0; inst $R multi-fec@relay 1.4.0; inst $R2 multi-fec@relay 1.4.0; inst $C multi-fec@client 1.4.0
  sleep 8
  for h in $C $R $R2 $S; do ssh "$h" 'echo "$(hostname) $(sha256sum /usr/sbin/multi-fec-dist | cut -c1-16) $(systemctl is-active multi-fec@client multi-fec@relay multi-fec@server 2>/dev/null | tr "\n" " ")"'; done
  ssh $C 'ping -c 5 -i 0.3 -W 1 -q 10.9.20.1 | tail -1'
}
mkdir -p raw; T0=$(date +%s)
trap restore EXIT
echo "[$(date +%T)] ##### 4대 $V 설치"
inst $S multi-fec@server $V; inst $R multi-fec@relay $V; inst $R2 multi-fec@relay $V; inst $C multi-fec@client $V
for i in $(seq 1 12); do ssh $C 'ping -c 3 -W 1 -q 10.9.20.1' >/dev/null 2>&1 && break; sleep 5; done
echo "  sha c/r/rs2/s $(for h in $C $R $R2 $S; do ssh $h 'sha256sum /usr/sbin/multi-fec-dist | cut -c1-8'; done | tr '\n' ' ')"
for e in $HOSTS; do IFS=: read k h u <<<"$e"
  ssh $h "setsid nohup bash -c 'echo t,pid,rss_kb,fd,thr > /tmp/soak_res.csv; while :; do p=\$(systemctl show -p MainPID --value $u); \
    echo \$(date +%s),\$p,\$(awk \"/VmRSS/{print \\\$2}\" /proc/\$p/status 2>/dev/null),\$(ls /proc/\$p/fd 2>/dev/null | wc -l),\$(ls /proc/\$p/task 2>/dev/null | wc -l) >> /tmp/soak_res.csv; sleep 30; done' \
    >/dev/null 2>&1 < /dev/null & echo \$! > /tmp/soak_res.pid"
done
sleep 20
RUNID=soak RATES=$RATE REPS=1 DUR=$DUR GAP=1 SCEN=steady ./tunnel_regress.sh | grep -E '^\[run\]|트립|기동 실패'
echo "[$(date +%T)] SOAK_DONE"
