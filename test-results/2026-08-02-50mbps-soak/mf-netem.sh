#!/bin/bash
# mf-netem.sh — multi-fec 경로별 임피어먼트(netem) 적용/해제
#
# 테스트망 전용. 두 경로에 서로 다른 지연·손실을 걸어 멀티패스 거동을 관찰한다.
#
# 배치가 c↔r 구간인 이유:
#   r→s 방향은 relay 와 relay@b 두 인스턴스가 upstream 소켓의 소스 IP 를 공유하므로
#   (둘 다 .85) IP 로 구분할 수 없다. 포트는 재시작마다 바뀌어 필터로 쓸 수 없다.
#   c↔r 구간에 걸면 경로 특성(RTT·손실)은 동일하고 IP 기반이라 재시작에 안전하다.
#
#     c → r   c 의 egress 에서 목적지 IP(.85/.86)로 분류
#     r → c   r 의 egress 에서 출발지 IP(.85/.86)로 분류
#
# 설정: /etc/multi-fec/netem.conf
# 사용: mf-netem.sh apply | clear | show
set -u

CONF=${CONF:-/etc/multi-fec/netem.conf}
[ -r "$CONF" ] || { echo "설정 없음: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${ROLE:?ROLE 필요 (client|relay)}"
: "${IFACE:?IFACE 필요}"
: "${P0_ADDR:?}" "${P1_ADDR:?}"
: "${P0_DELAY:?}" "${P0_LOSS:?}" "${P1_DELAY:?}" "${P1_LOSS:?}"
PORT=${PORT:-443}

clear_qdisc() { tc qdisc del dev "$IFACE" root 2>/dev/null || true; }

apply() {
    clear_qdisc
    # band 3 = 분류되지 않은 전부(관리 트래픽, r→s). 임피어먼트 없음.
    tc qdisc add dev "$IFACE" root handle 1: prio bands 3 \
        priomap 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
    tc qdisc add dev "$IFACE" parent 1:1 handle 10: netem delay "$P0_DELAY" loss "$P0_LOSS"
    tc qdisc add dev "$IFACE" parent 1:2 handle 20: netem delay "$P1_DELAY" loss "$P1_LOSS"
    tc qdisc add dev "$IFACE" parent 1:3 handle 30: fq_codel

    case "$ROLE" in
    client)
        # c → r : 목적지 릴레이 IP 로 분류
        tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
            match ip protocol 17 0xff \
            match ip dst "$P0_ADDR/32" match ip dport "$PORT" 0xffff flowid 1:1
        tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
            match ip protocol 17 0xff \
            match ip dst "$P1_ADDR/32" match ip dport "$PORT" 0xffff flowid 1:2
        ;;
    relay)
        : "${PEER:?relay 역할에는 PEER(클라이언트 IP) 필요}"
        # r → c : 출발지 릴레이 IP 로 분류. dst 를 함께 봐야 r→s 가 섞이지 않는다.
        tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
            match ip protocol 17 0xff \
            match ip src "$P0_ADDR/32" match ip sport "$PORT" 0xffff \
            match ip dst "$PEER/32" flowid 1:1
        tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
            match ip protocol 17 0xff \
            match ip src "$P1_ADDR/32" match ip sport "$PORT" 0xffff \
            match ip dst "$PEER/32" flowid 1:2
        ;;
    *) echo "알 수 없는 ROLE: $ROLE" >&2; exit 1 ;;
    esac
    echo "mf-netem: $ROLE/$IFACE  path0=$P0_DELAY/$P0_LOSS  path1=$P1_DELAY/$P1_LOSS"
}

case "${1:-apply}" in
    apply) apply ;;
    clear) clear_qdisc; echo "mf-netem: $IFACE qdisc 제거" ;;
    show)  tc -s qdisc show dev "$IFACE"; echo; tc -s class show dev "$IFACE" ;;
    *)     echo "사용법: $0 apply|clear|show" >&2; exit 1 ;;
esac
