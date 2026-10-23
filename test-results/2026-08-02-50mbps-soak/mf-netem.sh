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
# ROLE=relay-both (2026-10-22): r 이 양방향을 다 맡는다. c 에는 netem 을 걸지 않는다.
#     c → r   r 의 ingress 를 IFB(ifb0)로 돌려 거기서 목적지 IP 로 분류
#     r → c   r 의 egress (relay 와 같음)
#   이유: c 의 multi-fec 이 UDP GSO 로 묶어 보내면 그 덩어리가 잘리기 전에 c 의 netem 을 지나
#   덩어리째 버려진다(실회선에 없는 몰아치기 손실). 선 위에서 이미 개별 패킷이 된 뒤 r 에서 걸면 패킷 단위다.
#
# 2026-10-23: 경로마다 relay 호스트가 따로면(r=.88, rs2=.131) 호스트당 경로 1개 — P1_ADDR 을 비우면 path1 은 걸지 않는다.
#
# 설정: /etc/multi-fec/netem.conf
# 사용: mf-netem.sh apply | clear | show
set -u

CONF=${CONF:-/etc/multi-fec/netem.conf}
[ -r "$CONF" ] || { echo "설정 없음: $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

: "${ROLE:?ROLE 필요 (client|relay|relay-both)}"
: "${IFACE:?IFACE 필요}"
: "${P0_ADDR:?}" "${P0_DELAY:?}" "${P0_LOSS:?}"
P1_ADDR=${P1_ADDR:-}        # 비우면 path1 없음 (호스트당 경로 1개)
P1_DELAY=${P1_DELAY:-0ms}; P1_LOSS=${P1_LOSS:-0%}
# 선택: 경로 속도 제한 (예 P0_RATE=30mbit). 비우면 제한 없음. 제한 시 대기열은 RATE_LIMIT_PKTS(기본 300 패킷 ≈ 30 Mbps 에서 ~110 ms)
# — netem 기본 1000 이면 ~370 ms 버퍼라 실회선보다 지연이 커진다. 2026-10-23 경로별 속도 제한 계단 시험용
P0_RATE=${P0_RATE:-}; P1_RATE=${P1_RATE:-}
PORT=${PORT:-443}

IFB=${IFB:-ifb0}
# 수신 방향을 잡을 인터페이스들 (ROLE=relay-both). r 은 .117 이 ens19 에 붙어 있어 c→.117 이 ens19 로 들어온다
# (2026-10-22 실측: ens18 에만 걸면 path[1] 왕복이 31 ms — 한쪽 지연만 걸렸다). ARP 가 두 NIC 에서 답해 섞일 수 있어 둘 다 건다.
IN_IFACES=${IN_IFACES:-$IFACE}
clear_qdisc() {
    tc qdisc del dev "$IFACE" root 2>/dev/null || true
    for i in $IN_IFACES; do tc qdisc del dev "$i" ingress 2>/dev/null || true; done
    if ip link show "$IFB" >/dev/null 2>&1; then
        tc qdisc del dev "$IFB" root 2>/dev/null || true
        ip link del "$IFB" 2>/dev/null || true
    fi
}

# c → r 수신 방향을 IFB 로 돌려 netem 을 건다 (ROLE=relay-both)
apply_ingress() {
    modprobe ifb numifbs=0 2>/dev/null || true
    ip link show "$IFB" >/dev/null 2>&1 || ip link add "$IFB" type ifb
    ip link set "$IFB" up
    tc qdisc add dev "$IFB" root handle 1: prio bands 3 \
        priomap 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
    tc qdisc add dev "$IFB" parent 1:1 handle 10: netem delay "$P0_DELAY" loss "$P0_LOSS" ${P0_RATE:+rate $P0_RATE limit ${RATE_LIMIT_PKTS:-300}}
    tc qdisc add dev "$IFB" parent 1:2 handle 20: netem delay "$P1_DELAY" loss "$P1_LOSS" ${P1_RATE:+rate $P1_RATE limit ${RATE_LIMIT_PKTS:-300}}
    tc qdisc add dev "$IFB" parent 1:3 handle 30: fq_codel
    tc filter add dev "$IFB" protocol ip parent 1: prio 1 u32 \
        match ip protocol 17 0xff \
        match ip dst "$P0_ADDR/32" match ip dport "$PORT" 0xffff flowid 1:1
    [ -n "$P1_ADDR" ] && tc filter add dev "$IFB" protocol ip parent 1: prio 1 u32 \
        match ip protocol 17 0xff \
        match ip dst "$P1_ADDR/32" match ip dport "$PORT" 0xffff flowid 1:2
    # ingress: 클라이언트(PEER)에서 온 UDP:PORT 만 IFB 로 — 나머지 수신은 그대로
    for i in $IN_IFACES; do
        tc qdisc add dev "$i" handle ffff: ingress
        tc filter add dev "$i" parent ffff: protocol ip prio 1 u32 \
            match ip protocol 17 0xff \
            match ip src "$PEER/32" match ip dport "$PORT" 0xffff \
            action mirred egress redirect dev "$IFB"
    done
}

apply() {
    clear_qdisc
    # band 3 = 분류되지 않은 전부(관리 트래픽, r→s). 임피어먼트 없음.
    tc qdisc add dev "$IFACE" root handle 1: prio bands 3 \
        priomap 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2 2
    tc qdisc add dev "$IFACE" parent 1:1 handle 10: netem delay "$P0_DELAY" loss "$P0_LOSS" ${P0_RATE:+rate $P0_RATE limit ${RATE_LIMIT_PKTS:-300}}
    tc qdisc add dev "$IFACE" parent 1:2 handle 20: netem delay "$P1_DELAY" loss "$P1_LOSS" ${P1_RATE:+rate $P1_RATE limit ${RATE_LIMIT_PKTS:-300}}
    tc qdisc add dev "$IFACE" parent 1:3 handle 30: fq_codel

    case "$ROLE" in
    client)
        # c → r : 목적지 릴레이 IP 로 분류
        tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
            match ip protocol 17 0xff \
            match ip dst "$P0_ADDR/32" match ip dport "$PORT" 0xffff flowid 1:1
        [ -n "$P1_ADDR" ] && tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
            match ip protocol 17 0xff \
            match ip dst "$P1_ADDR/32" match ip dport "$PORT" 0xffff flowid 1:2
        ;;
    relay|relay-both)
        : "${PEER:?relay 역할에는 PEER(클라이언트 IP) 필요}"
        # r → c : 출발지 릴레이 IP 로 분류. dst 를 함께 봐야 r→s 가 섞이지 않는다.
        tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
            match ip protocol 17 0xff \
            match ip src "$P0_ADDR/32" match ip sport "$PORT" 0xffff \
            match ip dst "$PEER/32" flowid 1:1
        [ -n "$P1_ADDR" ] && tc filter add dev "$IFACE" protocol ip parent 1: prio 1 u32 \
            match ip protocol 17 0xff \
            match ip src "$P1_ADDR/32" match ip sport "$PORT" 0xffff \
            match ip dst "$PEER/32" flowid 1:2
        ;;
    *) echo "알 수 없는 ROLE: $ROLE" >&2; exit 1 ;;
    esac
    [ "$ROLE" = relay-both ] && apply_ingress
    echo "mf-netem: $ROLE/$IFACE  path0($P0_ADDR)=$P0_DELAY/$P0_LOSS${P0_RATE:+/$P0_RATE}  path1(${P1_ADDR:-없음})=$P1_DELAY/$P1_LOSS"
}

case "${1:-apply}" in
    apply) apply ;;
    clear) clear_qdisc; echo "mf-netem: $IFACE qdisc 제거" ;;
    show)  tc -s qdisc show dev "$IFACE"; echo; tc -s class show dev "$IFACE"
           ip link show "$IFB" >/dev/null 2>&1 && { echo "== $IFB"; tc -s qdisc show dev "$IFB"; } ;;
    *)     echo "사용법: $0 apply|clear|show" >&2; exit 1 ;;
esac
