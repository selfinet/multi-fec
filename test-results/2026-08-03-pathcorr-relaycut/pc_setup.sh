#!/bin/bash
# pc_setup.sh — c.xdn: 프로브 포트를 실제 경로와 같은 netem band 로 분류한다.
#
# 기존 mf-netem 필터는 pref 1 이고 dst IP + dport 443 을 매치한다.
# 프로브는 dport 40001 이라 그대로는 band 3(무임피어먼트)로 빠진다.
# 여기서 pref 2 로 프로브 포트용 필터만 추가하고, 끝나면 pref 2 통째로 지운다.
# 기존 pref 1 필터는 건드리지 않는다.
set -eu

IFACE=${IFACE:-enp2s0}
P0=${P0:-192.168.100.85}
P1=${P1:-192.168.100.86}
PORT=${PORT:-40001}
PREF=2

case "${1:-}" in
apply)
    for spec in "$P0 1:1" "$P1 1:2"; do
        set -- $spec
        sudo tc filter add dev "$IFACE" parent 1: protocol ip pref $PREF u32 \
            match ip protocol 17 0xff \
            match ip dst "$1"/32 \
            match ip dport "$PORT" 0xffff \
            flowid "$2"
    done
    echo "applied: dport $PORT -> netem bands (pref $PREF)"
    ;;
clear)
    sudo tc filter del dev "$IFACE" parent 1: pref $PREF 2>/dev/null || true
    echo "cleared pref $PREF"
    ;;
show)
    sudo tc -s qdisc show dev "$IFACE"
    echo "--- filters ---"
    sudo tc filter show dev "$IFACE" parent 1:
    ;;
*)
    echo "usage: $0 {apply|clear|show}" >&2
    exit 1
    ;;
esac
