#!/bin/bash
# maxbuf_1009.sh — 최대 처리량 + 레이트 × --sock-buf 매트릭스 (2026-10-09, 사용자 요청)
#
# 1단계: 1.3.6 · --sock-buf 4096 · sysctl 기본에서 계단 20/25/30/35/40 × 45초.
#        손실(상·하) < 0.1% 이고 가드 트립 전인 최고 레이트 = MAX. (가드 임계는 바꾸지 않는다 — 트립이 곧 상한)
# 2단계: --sock-buf 512 / 1024 / 2048 / 4096 kB 각각에 대해 5 Mbps ~ max(MAX,20) 를 5 간격으로 지속 540초, PING=1.
#        버퍼는 c·s 유닛 SOCK_BUF(conf) + relay drop-in 으로 바꾼다(1.3.6 은 *FORCE 라 sysctl 무관).
# 끝나면 무조건 원상 복구: conf 복원 → sysctl 파일 재적용 → drop-in 제거 → 3대 1.3.1 → 재시작 → 확인.
set -u
cd "$(dirname "$0")"
C=root@192.168.100.92; R=root@192.168.100.88; S=root@192.168.100.102
DI=/etc/systemd/system/multi-fec-relay.service.d/tp-sockbuf.conf
DIB=/etc/systemd/system/multi-fec-relay-b.service.d/tp-sockbuf.conf

restore() {
  echo "[$(date +%T)] ===== 원상 복구"
  ssh "$C" 'mv /etc/multi-fec/client.conf.bak-maxbuf /etc/multi-fec/client.conf 2>/dev/null'
  ssh "$S" 'mv /etc/multi-fec/server.conf.bak-maxbuf /etc/multi-fec/server.conf 2>/dev/null'
  ssh "$C" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$S" 'sysctl -qp /etc/sysctl.d/90-multi-fec.conf'
  ssh "$R" 'sysctl -qp /etc/sysctl.d/90-multi-fec-relay.conf'
  ssh "$R" "rm -f $DI $DIB; rmdir /etc/systemd/system/multi-fec-relay.service.d /etc/systemd/system/multi-fec-relay-b.service.d 2>/dev/null; systemctl daemon-reload"
  ssh "$S" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-server'
  ssh "$R" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-relay multi-fec-relay-b'
  ssh "$C" 'install -m 755 /usr/sbin/multi-fec-dist.v1.3.1 /usr/sbin/multi-fec-dist && systemctl restart multi-fec-client'
  sleep 8
  for h in $C $R $S; do
    ssh "$h" 'echo "$(hostname) $(sysctl -n net.core.rmem_max net.core.rmem_default | tr "\n" " ")$(md5sum /usr/sbin/multi-fec-dist | cut -c1-8) dropin=$(ls /etc/systemd/system/multi-fec-relay*.d 2>/dev/null | wc -l) $(grep -h ^SOCK_BUF /etc/multi-fec/*.conf 2>/dev/null) $(systemctl is-active multi-fec-client multi-fec-relay multi-fec-relay-b multi-fec-server 2>/dev/null | tr "\n" " ")"'
  done
  ssh "$C" 'ping -c 3 -W 1 -q 10.9.20.1 | tail -2'
  echo "sv1 운영: $(systemctl show multi-fec-server -p MainPID -p ActiveEnterTimestamp | tr '\n' ' ') md5 $(md5sum /usr/sbin/multi-fec-dist 2>/dev/null | cut -c1-8)"
}
trap restore EXIT

setbuf() {  # kB — c·s conf + relay drop-in. 재시작은 tp_ladder 가 한다
  ssh "$C" "sed -i 's/^SOCK_BUF=.*/SOCK_BUF=$1/' /etc/multi-fec/client.conf"
  ssh "$S" "sed -i 's/^SOCK_BUF=.*/SOCK_BUF=$1/' /etc/multi-fec/server.conf"
  for u in multi-fec-relay multi-fec-relay-b; do
    ssh "$R" "mkdir -p /etc/systemd/system/$u.service.d && cat > /etc/systemd/system/$u.service.d/tp-sockbuf.conf" <<EOF2
# 2026-10-09 maxbuf_1009.sh 임시 drop-in (끝나면 제거)
[Service]
ExecStart=
ExecStart=/usr/sbin/multi-fec-dist -r -l \${LISTEN} --upstream \${UPSTREAM} --upstream-local \${UPSTREAM_LOCAL} -k \${KEY} --obfs-mode quic --auth-interval \${AUTH_INTERVAL} --log-level \${LOG_LEVEL} --sock-buf $1
EOF2
  done
  ssh "$R" 'systemctl daemon-reload'
}

ssh "$C" 'cp -p /etc/multi-fec/client.conf /etc/multi-fec/client.conf.bak-maxbuf'
ssh "$S" 'cp -p /etc/multi-fec/server.conf /etc/multi-fec/server.conf.bak-maxbuf'

# ── 1단계: 최대 처리량
setbuf 4096
echo "[$(date +%T)] ##### 1단계 최대 처리량 (4096)"
COMBOS=M4096:136:136:136:def OUT=raw/max_lad PFX=maxl PING=1 STEPS="20 25 30 35 40" DUR=45 ./tp_ladder.sh
# 트립한 단계는 결과 줄이 찍혀도 제외한다 (run_load 는 줄을 찍은 뒤 트립을 확인한다)
L=$(grep -E '^\[run\] +[0-9]+ Mbps' raw/max_lad/M4096/run.out); grep -q '트립' raw/max_lad/M4096/run.out && L=$(echo "$L" | sed '$d')
MAX=$(echo "$L" | awk '{u=$5; d=$9; gsub("%","",u); gsub("%","",d);
  if (u+0 < 0.1 && d+0 < 0.1 && !bad) m=$2; else bad=1} END {print m+0}')
grep -q '트립' raw/max_lad/M4096/run.out && echo "[$(date +%T)] 1단계 가드 트립: $(grep -m1 트립 raw/max_lad/M4096/run.out | cut -c1-120)"
echo "[$(date +%T)] 1단계 MAX=$MAX Mbps (손실 <0.1% · 트립 전 최고)"
TOP=$MAX; [ "$TOP" -lt 20 ] && TOP=20
STEPS2=$(seq 5 5 $TOP | tr '\n' ' ')
echo "[$(date +%T)] 2단계 STEPS=$STEPS2"

# ── 2단계: 레이트 × 버퍼
for kb in 512 1024 2048 4096; do
  setbuf $kb
  echo "[$(date +%T)] ##### 2단계 sock-buf=$kb"
  COMBOS=B$kb:136:136:136:def OUT=raw/mb_soak PFX=mbs PING=1 STEPS="$STEPS2" DUR=540 ./tp_ladder.sh
done
echo "[$(date +%T)] 측정 완료"
