#!/bin/bash
# sampler3.sh <label> <iface> <service> <out.csv> <dur_s> <iv_s>
# 프로세스 CPU/RSS/FD + 인터페이스 TX/RX + (있으면) netem 밴드
#   → <out.csv>
# 시스템 전체 per-CPU 이용률 (mpstat -P ALL 과 동일 항목)
#   → <out>_cpu.csv          ★ v3 추가분
#
# ★ 2026-08-02 추가: 호스트 UDP 카운터(/proc/net/snmp) — <out.csv> 뒤에 컬럼 추가
#   CPU% 만 보면 포화를 늦게 안다. 이벤트 루프가 소켓을 못 비우면 커널 수신 버퍼가 차고
#   **커널이 조용히 버리는데** 애플리케이션은 에러를 못 받는다. 이 드롭은 /proc/net/snmp 의
#   RcvbufErrors 로만 보이며, 열화 순서는 ① RTT 상승 ② 커널 드롭 ③ FEC 복구 마감 초과
#   ④ 종단 손실 이다. 즉 **RcvbufErrors 증가가 CPU% 보다 이른 실질 경보**다.
#   rcvbuf_d(직전 샘플 대비 증가분)가 0 이 아니면 그 시점부터 이미 흘리고 있다는 뜻.
#   주의: 호스트 전체 값이라 multi-fec 만의 것이 아니다(iperf3·WG 등 포함). 귀속이 필요하면
#   `ss -unmp` 의 소켓별 드롭을 따로 봐야 한다.
#
# v2(mf_sampler2.sh) 대비 변경: per-CPU 사이드카 CSV 추가. 기존 CSV 스키마는 무변경이라
# 기존 분석 스크립트가 그대로 동작한다.
#
# 왜 mpstat 바이너리를 직접 안 쓰는가 (셋 다 실측 근거):
#   1) r.xdn 에 sysstat 미설치 (c/s 는 있음) — 3대 중 1대만 데이터가 비는 것을 피한다
#   2) mpstat 은 LC_NUMERIC 을 따라 소수점을 ',' 로 찍는다. 테스트망 3대 모두 ko_KR 로케일이라
#      CSV 가 깨진다 (LC_ALL=C 로 우회 가능하지만 의존성은 남는다)
#   3) `mpstat -P ALL 1 1` 은 샘플 주기 60초 중 1초만 본다. 아래 방식은 /proc/stat 누적
#      카운터의 델타라 주기 전체를 100% 커버한다 (= `mpstat -P ALL 60` 과 동등)
# 계산식은 mpstat 과 동일하다: 분모 = user..steal 8개 필드 합,
# %usr = (user-guest)/tot, %nice = (nice-gnice)/tot. 컬럼명도 mpstat 표기를 따랐다.
set -u
L=$1; IF=$2; SVC=$3; OUT=$4; DUR=$5; IV=$6
END=$(( $(date +%s) + DUR ))
HZ=$(getconf CLK_TCK)
SYS_OUT="${OUT%.csv}_cpu.csv"
echo "ts,label,pid,cpu_pct,rss_kb,fds,if_tx_bytes,if_rx_bytes,b11_sent,b11_drop,b12_sent,b12_drop,udp_in,udp_inerr,udp_rcvbuferr,udp_sndbuferr,rcvbuf_d" > "$OUT"
echo "ts,label,cpu,usr,nice,sys,iowait,irq,soft,steal,guest,gnice,idle,busy" > "$SYS_OUT"
prev_cpu=""; prev_t=""; prev_stat=""; prev_rcv=""
while [ "$(date +%s)" -lt "$END" ]; do
  now=$(date +%s)
  pid=$(systemctl show -p MainPID --value "$SVC" 2>/dev/null)
  cpu=""; rss=""; fds=""
  if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -r "/proc/$pid/stat" ]; then
      st=$(awk '{print $14, $15}' /proc/$pid/stat)
      ut=${st% *}; kt=${st#* }; tot=$(( ut + kt ))
      rss=$(awk '/VmRSS/{print $2}' /proc/$pid/status 2>/dev/null)
      fds=$(ls /proc/$pid/fd 2>/dev/null | wc -l)
      if [ -n "$prev_cpu" ] && [ "$now" != "$prev_t" ]; then
          cpu=$(awk -v a=$tot -v b=$prev_cpu -v dt=$((now-prev_t)) -v hz=$HZ 'BEGIN{printf "%.2f",(a-b)*100.0/hz/dt}')
      fi
      prev_cpu=$tot; prev_t=$now
  fi
  # ── 시스템 전체 per-CPU ────────────────────────────────────────────────────
  # cpu="all" 행이 mpstat 의 "all" 과 같다. cpu_pct(프로세스)는 논리 CPU 1개가 100% 기준이고
  # 이쪽은 코어별로 각각 100% 기준이라 스케일이 다르다 — 비교할 때 주의.
  cur_stat=$(grep '^cpu' /proc/stat)
  if [ -n "$prev_stat" ]; then
    { printf '%s\n' "$prev_stat"; echo '@@'; printf '%s\n' "$cur_stat"; } |
    awk -v ts="$now" -v lab="$L" '
      $1=="@@" { p=1; next }
      !p { for (i=2; i<=11; i++) a[$1 SUBSEP i] = $i+0; next }
      {
        n=$1; tot=0
        for (i=2; i<=9; i++) { d[i] = ($i+0) - a[n SUBSEP i]; tot += d[i] }
        if (tot <= 0) next          # 카운터 wrap / 오프라인 코어 / 동일 tick
        g  = ($10+0) - a[n SUBSEP 10]
        gn = ($11+0) - a[n SUBSEP 11]
        c  = (n=="cpu") ? "all" : substr(n,4)
        printf "%s,%s,%s,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f\n",
               ts, lab, c,
               (d[2]-g)*100/tot, (d[3]-gn)*100/tot, d[4]*100/tot,
               d[6]*100/tot, d[7]*100/tot, d[8]*100/tot, d[9]*100/tot,
               g*100/tot, gn*100/tot, d[5]*100/tot, 100 - d[5]*100/tot
      }' >> "$SYS_OUT"
  fi
  prev_stat=$cur_stat
  tx=$(awk -v i="$IF:" '$1==i{print $10}' /proc/net/dev)
  rx=$(awk -v i="$IF:" '$1==i{print $2}'  /proc/net/dev)
  b11s=""; b11d=""; b12s=""; b12d=""
  if tc -s class show dev "$IF" >/dev/null 2>&1; then
     read b11s b11d < <(tc -s class show dev "$IF" 2>/dev/null | awk '/class prio 1:1 /{f=1;next} f&&/Sent/{gsub(/,/,"",$2); gsub(/,/,"",$7); print $2, $7; exit}')
     read b12s b12d < <(tc -s class show dev "$IF" 2>/dev/null | awk '/class prio 1:2 /{f=1;next} f&&/Sent/{gsub(/,/,"",$2); gsub(/,/,"",$7); print $2, $7; exit}')
  fi
  # ── 호스트 UDP 카운터 ──────────────────────────────────────────────────────
  # /proc/net/snmp 의 두 번째 "Udp:" 줄이 값이다:
  #   $2 InDatagrams  $4 InErrors  $6 RcvbufErrors  $7 SndbufErrors
  read -r uin uerr urcv usnd < <(awk '/^Udp:/{if(++n==2){print $2, $4, $6, $7; exit}}' /proc/net/snmp)
  rcvd=""
  [ -n "$prev_rcv" ] && rcvd=$(( ${urcv:-0} - prev_rcv ))
  prev_rcv=${urcv:-0}

  echo "$now,$L,$pid,$cpu,$rss,$fds,$tx,$rx,$b11s,$b11d,$b12s,$b12d,$uin,$uerr,$urcv,$usnd,$rcvd" >> "$OUT"
  sleep "$IV"
done
