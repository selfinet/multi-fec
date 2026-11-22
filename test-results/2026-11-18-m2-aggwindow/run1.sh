#!/bin/bash
# 2026-11-18 aggregate 송신창 재현 — .92 client(J1900) ↔ .93 server(J1900), enp4s0 1G 직결, path0 30ms / path1 54ms 편도
J='-o BatchMode=yes -o ConnectTimeout=8 -J stevekim@10.0.3.3'
C=root@192.168.2.92; S=root@192.168.2.93
cd "$(dirname "$0")"; mkdir -p raw
mon() { # $1 tag $2 seconds
  for h in $C $S; do n=${h##*.}
    ssh $J $h "cd /root/rq; p=\$(cat client.pid server.pid 2>/dev/null | head -1); mf=\$(pgrep -P \$p multi-fec-dist || echo \$p);
      LC_ALL=C setsid timeout $(( $2 + 3 )) pidstat -h -u -p \$mf 1 > mon_$1_pid.txt 2>&1 < /dev/null &
      LC_ALL=C setsid timeout $(( $2 + 3 )) mpstat -P ALL 1 > mon_$1_cpu.txt 2>&1 < /dev/null &" ; done; }
run() { # tag dst dur extra
  echo "== $1 $(date +%T)"
  mon $1 $3
  ssh $J $C "date +%s > /root/rq/t_$1; iperf3 -c $2 -P 8 -t $3 -i 1 $4" > raw/iperf_$1.txt 2>&1
  grep -E "SUM.*(sender|receiver)" raw/iperf_$1.txt
  sleep 5
}
run base_p0_up   172.31.10.1 20 ""
run base_p0_down 172.31.10.1 20 "-R"
run base_p1_up   172.31.11.1 20 ""
run base_p1_down 172.31.11.1 20 "-R"
run tun_up       10.89.0.1   60 ""
run tun_down     10.89.0.1   60 "-R"
for h in $C $S; do n=${h##*.}; scp -q $J "$h:/root/rq/mon_*" raw/ 2>/dev/null; for f in raw/mon_*; do [ -f "$f" ] && mv "$f" "${f%.txt}_$n.txt"; done; done
scp -q $J $C:/root/rq/client.log raw/client.log; scp -q $J $S:/root/rq/server.log raw/server.log
echo done
