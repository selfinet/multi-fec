#!/bin/bash
# spof_test.sh — 이중화 격리 경계 실측 (테스트망 전용)
#
# 문서의 주장: "경로 2개는 **프로세스 장애만** 분리한다. 호스트·NIC 은 공유이므로
# 릴레이 호스트와 서버 호스트가 단일 장애점이다."  그 주장을 세 단계로 확인한다.
#
#   A. 릴레이 프로세스 1개 정지   → duplicate 가 커버해야 한다 (공백 0 기대)
#   B. 릴레이 프로세스 2개 정지   → **호스트 장애 대리**. 전면 단절 기대
#   C. 복구                       → 자동 회복 여부와 지연
#
# 프로브는 WG IP 사이 ping (규칙 1). 5 pps 라 부하 시험이 아니다.
set -u
C=c.xdn.selfinet.com; R=r.xdn.selfinet.com
OUT=${OUT:-/home/stevekim/multi-fec/test-results/2026-09-09-spof}
mark() { echo "$(date +%s.%N) $*" >> $OUT/events.log; echo "[$(date +%H:%M:%S)] $*"; }

: > $OUT/events.log
ssh $C "pkill -f '[p]ing -i 0.2 -D 10.9.10.1'; exit 0" 2>/dev/null
ssh $C "setsid nohup ping -i 0.2 -D 10.9.10.1 </dev/null >/tmp/spof_ping.log 2>&1 & sleep 1; exit 0" 2>/dev/null
mark "프로브 시작 (ping 5pps over WG)"
sleep 20

mark "A: 릴레이 1개 정지 (multi-fec-relay = path[0] .85)"
ssh $R 'systemctl stop multi-fec-relay' 2>/dev/null
sleep 25
mark "A: 복구"
ssh $R 'systemctl start multi-fec-relay' 2>/dev/null
sleep 30

mark "B: 릴레이 2개 동시 정지 (호스트 장애 대리)"
ssh $R 'systemctl stop multi-fec-relay multi-fec-relay@b' 2>/dev/null
sleep 25
mark "B: 복구"
ssh $R 'systemctl start multi-fec-relay multi-fec-relay@b' 2>/dev/null
sleep 40
mark "종료"

ssh $C "pkill -f '[p]ing -i 0.2 -D 10.9.10.1'; exit 0" 2>/dev/null
ssh $C 'cat /tmp/spof_ping.log' > $OUT/ping.log 2>/dev/null
echo "  릴레이 상태: $(ssh $R 'systemctl is-active multi-fec-relay multi-fec-relay@b | tr "\n" " "' 2>/dev/null)"
wc -l $OUT/ping.log
