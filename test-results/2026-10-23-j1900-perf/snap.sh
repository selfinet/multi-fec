#!/bin/bash
# snap.sh <host> — 복구 대조용 상태 스냅샷 (시각·카운터 등 변하는 값은 뺀다)
ssh -o BatchMode=yes "$1" 'echo "## ip addr"; ip -br addr; echo "## ip link"; ip -br link | awk "{print \$1, \$2}"; echo "## ip route"; ip route
  echo "## sysctl"; sysctl net.core.rmem_max net.core.rmem_default net.core.wmem_max net.core.wmem_default
  echo "## wg"; wg show 2>&1; echo "## udp listen"; ss -Hulpn | awk "{print \$4}" | sort
  echo "## units"; systemctl list-units --all --no-legend "mft*" "multi-fec*" "wg-quick*"
  echo "## /opt"; ls /opt; echo "## qdisc"; tc qdisc show | sed "s/ refcnt [0-9]*//"; echo "## /etc/wireguard"; ls /etc/wireguard 2>&1
  echo "## sysctl.d"; ls /etc/sysctl.d; echo "## /tmp mft"; ls /tmp | grep -c mft'
