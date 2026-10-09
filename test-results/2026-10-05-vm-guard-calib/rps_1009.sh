#!/bin/bash
# rps_1009.sh — RPS(rps_cpus) A/B (2026-10-09, 사용자 요청)
#
# 조건: 3대 1.3.6 · sysctl 기본(212992) · 1단 --upstream · relay drop-in --sock-buf 4096 (= cmp_1009 의 B).
#   버퍼 드롭을 걷어낸 조건이라야 수신 softirq 분산 효과가 보인다.
# RPS 끔(0) / 켬(3 = CPU0+1) 을 번갈아 4회: R0 끔 → R1 켬 → R2 끔 → R3 켬 (런 간 편차가 커서 반복).
#   대상: c ens18 · r ens18 + ens19 · s ens18 의 rx-0 (세 호스트 모두 수신 큐 1개).
# 회차마다: 계단 5/10/15/20/25 × 45초 + 지속 15/20 × 540초, PING=1. 코어별 NET_RX softirq 전후 기록.
# 끝나면 무조건 원상 복구: rps 0 → sysctl 파일 재적용 → drop-in 제거 → 3대 1.3.1 → 재시작 → 확인.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
DI=/etc/systemd/system/multi-fec-relay.service.d/tp-sockbuf.conf
DIB=/etc/systemd/system/multi-fec-relay-b.service.d/tp-sockbuf.conf

setrps() {  # 0 | 3
  ssh "$C" "echo $1 > /sys/class/net/ens18/queues/rx-0/rps_cpus"
  ssh "$R" "echo $1 > /sys/class/net/ens18/queues/rx-0/rps_cpus; echo $1 > /sys/class/net/ens19/queues/rx-0/rps_cpus"
  ssh "$S" "echo $1 > /sys/class/net/ens18/queues/rx-0/rps_cpus"
}
netrx() { for p in "c $C" "r $R" "s $S"; do set -- $p
  echo "$1 $(ssh "$2" 'grep NET_RX /proc/softirqs; cat /sys/class/net/ens1[89]/queues/rx-0/rps_cpus | tr "\n" " "')"; done; }

restore() {
  echo "[$(date +%T)] ===== 원상 복구"
  setrps 0
  ssh "$C" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$S" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$R" 'sysctl -qp /etc/sysctl.d/90-multi-fec-relay.conf'
  ssh "$R" "rm -f $DI $DIB; rmdir /etc/systemd/system/multi-fec-relay.service.d /etc/systemd/system/multi-fec-relay-b.service.d 2>/dev/null; systemctl daemon-reload"
  ssh "$S" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server'
  ssh "$R" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b'
  ssh "$C" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client'
  sleep 8
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(sysctl -n net.core.rmem_max net.core.rmem_default | tr "\n" " ")$(md5sum /usr/sbin/multi-fec-dist | cut -c1-8) rps=$(cat /sys/class/net/ens1[89]/queues/rx-0/rps_cpus | tr "\n" ",") dropin=$(ls /etc/systemd/system/multi-fec-relay*.d 2>/dev/null | wc -l) $(systemctl is-active multi-fec-client multi-fec-relay multi-fec-relay-b multi-fec-server 2>/dev/null | tr "\n" " ")"'
  done
  ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1 | tail -2'
  echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
}
trap restore EXIT

# relay drop-in (--sock-buf 4096)
for u in multi-fec-relay multi-fec-relay-b; do
  ssh "$R" "mkdir -p /etc/systemd/system/$u.service.d && cat > /etc/systemd/system/$u.service.d/tp-sockbuf.conf" <<'EOF'
# 2026-10-09 RPS A/B 용 임시 drop-in (rps_1009.sh 가 끝나면 제거)
[Service]
ExecStart=
ExecStart=/usr/sbin/multi-fec-dist -r -l ${LISTEN} --upstream ${UPSTREAM} --upstream-local ${UPSTREAM_LOCAL} -k ${KEY} --obfs-mode quic --auth-interval ${AUTH_INTERVAL} --log-level ${LOG_LEVEL} --sock-buf 4096
EOF
done
ssh "$R" 'systemctl daemon-reload'

mkdir -p raw/rps
for run in R0:0 R1:3 R2:0 R3:3; do
  X=${run%%:*}; V=${run##*:}
  setrps $V
  echo "[$(date +%T)] ##### $X rps=$V 계단"
  netrx > raw/rps/${X}_netrx_before.txt
  COMBOS=$X:136:136:136:def OUT=raw/rps_lad PFX=rpsl PING=1 STEPS="5 10 15 20 25" DUR=45 ./tp_ladder.sh
  echo "[$(date +%T)] ##### $X rps=$V 지속"
  COMBOS=$X:136:136:136:def OUT=raw/rps_soak PFX=rpss PING=1 STEPS="15 20" DUR=540 ./tp_ladder.sh
  netrx > raw/rps/${X}_netrx_after.txt
done
echo "[$(date +%T)] 측정 완료"
