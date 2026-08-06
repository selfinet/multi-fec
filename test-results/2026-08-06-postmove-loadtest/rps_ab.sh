#!/bin/bash
# rps_ab.sh — c 의 RPS(rps_cpus) A/B. 하향 단일 TCP 로 goodput·코어별 CPU 를 잰다.
#
# 왜 스크립트 파일인가: 명령줄에 프로세스 패턴 문자열이 들어가면 `pgrep -f`/`pkill -f` 가
# **자기 자신을 매치**한다. 이 세션에서 다섯 번 걸렸다. 로직을 파일로 빼면 호출 명령줄이
# 짧아 그 함정을 구조적으로 피한다.
#
# ⚠️ `wait` 를 인자 없이 쓰지 말 것 — 같은 셸의 **가드까지** 기다려 영원히 멈춘다.
#    반드시 `wait <PID>`.
# ⚠️ 가드 생존 판정은 argv[1] 로 한다. `pgrep -f mf_gwguard` 는 호출 셸을 잡는다.
set -u
C=${C:-c.xdn.selfinet.com}
IF=${IF:-enp2s0}
DUR=${DUR:-26}
TRIALS=${TRIALS:-2}
VARIANTS=${VARIANTS:-"0 3 e"}
OUT=${OUT:-/tmp}

guard_alive() {
  local p a1
  for p in /proc/[0-9]*; do
    a1=$(tr '\0' '\n' < "$p/cmdline" 2>/dev/null | sed -n 2p)
    case "$a1" in *mf_gwguard.sh) return 0;; esac
  done
  return 1
}

set_rps() { ssh "$C" "echo $1 | sudo tee /sys/class/net/$IF/queues/rx-0/rps_cpus >/dev/null"; }
get_rps() { ssh "$C" "cat /sys/class/net/$IF/queues/rx-0/rps_cpus"; }

percore() {  # 3초 창 코어별 busy%
  ssh "$C" 'A=$(grep -E "^cpu[0-9]" /proc/stat); sleep 3; B=$(grep -E "^cpu[0-9]" /proc/stat)
    printf "%s\n===\n%s\n" "$A" "$B" | awk "/^===\$/{s=1;next}
      {b=\$2+\$3+\$4+\$7+\$8+\$9; t=b+\$5+\$6
       if(!s){B0[\$1]=b;T0[\$1]=t} else {printf \"%s=%.0f \", \$1, (b-B0[\$1])/(t-T0[\$1])*100}}"' 2>/dev/null
}

trap 'echo "[정리] rps_cpus=0 원복"; set_rps 0' EXIT

printf "%-6s %-3s %-11s %s\n" "rps" "#" "하향 Mbps" "코어별 busy%"
for v in $VARIANTS; do
  set_rps "$v"; real=$(get_rps)
  for n in $(seq 1 "$TRIALS"); do
    if ! guard_alive; then echo "  ✗ 가드 없음 — 중단"; exit 2; fi
    L=$OUT/rps_${v}_${n}.log
    ssh "$C" "iperf3 -c 10.9.10.1 -p 5201 -t $DUR -R" >"$L" 2>&1 &
    IP=$!                      # ← 반드시 특정 PID 로 wait
    sleep 9
    cores=$(percore)
    wait "$IP" 2>/dev/null
    bw=$(awk '/receiver/{print $7}' "$L")
    printf "%-6s %-3s %-11s %s\n" "$real" "$n" "${bw:-?}" "$cores"
    sleep 3
  done
done
