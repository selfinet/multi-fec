#!/bin/bash
# mf_gwguard.sh — 테스트망 부하 감시·차단. 모든 부하 하네스가 이걸 쓴다.
#
# 이름은 역사적이다 (2026-08-05)
# ---------------------------------
# 원래는 gw ens18 대역폭을 대리지표로 감시했다. 지금은 **호스트 부하**를 본다.
# 파일명을 유지하는 이유는 기존 하네스 호출부가 전부 이 이름을 쓰고 있어서다 —
# 안전 도구는 호출부가 조용히 어긋나는 것이 가장 위험하다.
#
# 왜 지표를 바꿨나 (2026-08-05)
# ---------------------------------
# s 리슨이 192.168.100.84 로 옮겨져 c·r·s 가 전부 같은 /24 가 됐다. 데이터 경로가
# 전부 온링크가 되어 **gw 는 경로에서 빠졌다**(s 캡처의 이더넷 헤더가 r↔s 직결이고
# gw MAC 이 나타나지 않음). 즉 이전 대리지표(`s ens18` RX+TX)는 gw 에 도달하지도 않는
# 트래픽을 재고 있었다. 과대보고라 위험한 방향은 아니지만 보호 기능이 없는 것과 같다.
#
# 설계 변경 — 프록시를 버리고 제약을 직접 잰다
# ---------------------------------
# 2026-08-02 와 2026-08-03 사고의 공통 원인은 계산이 아니라 **대리지표가 조용히
# 무효해진 것**이었다 (c enp2s0 → gw 를 안 지남 / s ens18 → gw 를 안 지남).
# 그래서 이제 프록시를 쓰지 않고 **실제로 먼저 걸리는 것을 그 자리에서 잰다.**
#
#   ① c 의 CPU        — 용량 모델의 제약 ①. 대개 이게 먼저 걸린다
#   ② 가장 바쁜 1코어 — 제약 ②·③. multi-fec 은 단일 스레드이고 NIC 수신 softirq 가
#                        rx-0 단일 큐 + IRQ25 로 cpu2 에 고정된다 (rps 비활성)
#   ③ 링크 사용률     — 증폭 루프 백스톱. 2026-08-03 의 800 Mbps 사고는 WG 가 하부망을
#                        터널로 라우팅해 duplicate 가 한 바퀴마다 2배가 된 것이었다.
#                        토폴로지와 무관하게 그 종류의 폭주를 즉시 잡는다
#
# 세 호스트를 모두 본다. 병목이 옮겨가도 눈이 멀지 않게 하는 것이 요점이다.
#
# 용량 모델 (c.xdn Atom N2600, 2026-08-02 실측)
# ---------------------------------
#   인스턴스당 비용 = 0.0181 + 0.1067 × R      (논리CPU, R = 앱 Mbps 양방향)
#   ① 총량  N×0.0181 + 0.1067×ΣR ≤ 예산    예산: 안전 1.6 / 보통 2.0 / 한계 2.5 논리CPU
#   ② 개별  각 R ≤ 15.9 Mbps               단일 스레드
#   ③ NIC   ΣR ≤ 31.25 Mbps 양방향         단일 큐
#   논리 4개지만 물리 2개(HT) → 실효 2.5코어 상당, busy **62% 가 포화점**.
#   ⚠️ 12 Mbps 한 점에서 잰 선형 외삽이고 미확정 요소가 전부 불리한 방향이다.
#
# 검증 (2026-08-05, 네트워크 트래픽 없이)
# ---------------------------------
#   지표 산식   c 에서 1코어 점유 → 전체 27.1% / 최고1코어 100.0%
#               c 에서 2코어 점유 → 전체 51.0% / 최고1코어 100.0%   (4논리 기준 정확)
#   kill 경로   표적을 로컬·c 양쪽에 띄우고 임계값 0 으로 트립시켜 PID 로 판정.
#               조상 제외 **미적용** 시: 로컬 dead / **c alive** / guard rc=137(자기 SIGKILL)
#               조상 제외   적용 시: 로컬 dead /   c dead   / guard rc=2
#               → 부하 생성기는 c 에서 도므로 미적용 상태는 "가드가 부하를 못 멈춤" 이었다.
#
#   ⚠️ 검증할 때 `pgrep -c <패턴>` 으로 생존을 세지 말 것 — 그 명령을 담은 **셸 자신**이
#      매치되어 "살아 있다" 고 오판한다(2026-08-05 에 실제로 한 번 틀렸다). PID 로 판정한다.
#
#   실제 부하 하에서의 대조는 아직 하지 않았다. 첫 런의 첫 30초에 `sample` 로 대조할 것.
#
# 임계 재보정 (2026-09-05, 지속 소크 실측) — 이전 근거는 계단이었다
# ---------------------------------
# 이전 값(전체 62 / 1코어 85)은 2026-08-06 **45초 계단**에서 정했다. 계단은 단계 시작
# 8초 뒤 3회 평균이라 램프 구간이 섞여 **CPU 를 과소평가한다** — 같은 앱 각 22 Mbps 가
# 계단에서 72.8%, 지속 소크의 연속 샘플에서는 85~90% 로 읽힌다. 그래서 지속 부하에서는
# 정상 구간에 임계가 붙어 오탐했다: **앱 각 20 Mbps 는 32분간 손실·CPU·메모리가 전혀
# 나빠지지 않았는데도** 1코어 85 에 걸려 트립했다(그 사이 초과 106회).
#
# 재보정은 **지속 소크의 1초 샘플**로 했다. 정상 런과 실패 런의 실측 분포:
#
#   런                     c 전체 (초과 샘플 값)        c 최고1코어
#   정상 16M 1시간         62.3  62.5                  초과 없음
#   정상 18M 1시간         63.5 ~ 64.3 (4회)           초과 없음
#   정상 20M 32분          초과 없음                    85.1 ~ 87.5 (106회, 88 이상 0회)
#   정상 20M 1시간         62.4 (1회)                   93.2 (1회, 종료 직전)
#   ─────────────────────────────────────────────────────────────────
#   붕괴 24M (169초에 손실 15%)   72.0  72.0  76.1      90.6  92.5  94.2
#   실패 18M (08-07, 21분)        62.4 → 73.5 (31회 상승) 91.1
#
# **c 전체가 진짜 판별자다** — 정상은 최대 64.3, 붕괴·실패는 72 이상으로 확실히 갈린다.
# 최고1코어는 정상 대역(≤87.5)과 붕괴(90.6~94.2)가 갈리기는 하나 종료 전환 구간에서
# 93.2 가 한 번 나와 여유가 좁다. 그래서 **전체를 1차, 1코어를 보조**로 둔다.
#
#   전체 68  : 정상 최대 64.3 대비 +3.7p, 붕괴 72.0 대비 −4.0p
#   1코어 90 : 정상 대역 87.5 대비 +2.5p. 앱 각 20 Mbps 1시간 완주로 검증(초과 8회·트립 0,
#              그나마 대부분 c 가 아니라 r 이었다)
#
# ⚠️ **이 가드는 붕괴 탐지기가 아니다.** 24M 붕괴는 60초 간격 샘플에서 최고1코어가
# 78~80% 로 **정상 20M(86.9%)보다 낮게** 보였다 — CPU 로는 예고되지 않고 손실이 먼저
# 터진다. 손실 SLO 는 수신측 초 단위 계측으로 봐야 하고 가드로 대신할 수 없다.
# 가드의 역할은 **호스트 과부하와 증폭 폭주를 멈추는 백스톱**이다(링크 400 Mbps 는 무변경).

set -u

C=${GUARD_C:-c.xdn.selfinet.com}
R=${GUARD_R:-r.xdn.selfinet.com}
S=${GUARD_S:-s.xdn.selfinet.com}

# 부하 생성기가 도는 호스트들. 워치독은 여기서도 죽여야 한다 —
# 2026-08-03: sv1 로컬에서만 pkill 해서 원격 부하가 안 죽고 무방비로 계속 돌았다.
KILL_HOSTS=${GW_KILL_HOSTS:-"$C $R $S"}

INTERVAL=${GW_INTERVAL:-1}

# ── ssh 연결 재사용 (2026-09-05) ───────────────────────────────────
# 왜: 샘플마다 ssh 를 새로 맺으면 **피측정 호스트에서 sshd + 키교환 비용**이 발생한다.
# c(Atom N2600) 에서 실측 — 트래픽 0 인데 가드 가동만으로 전체 busy 0.7% → 10.5%,
# 코어별로 +8~12p. 실제 1코어가 73~77% 인 구간(앱 각 22 Mbps)에서 이 오버헤드가
# 얹혀 85% 임계를 넘겨 **손실 0 인데 트립**했다(2026-09-05 22 Mbps 소크, 21초).
# ControlMaster 로 연결을 1회만 맺고 재사용하면 매 샘플의 접속 비용이 사라진다.
# **임계값과 판정 로직은 건드리지 않는다** — 도구가 피측정계를 흔드는 것만 없앤다.
GW_CM_DIR=${GW_CM_DIR:-/tmp/mf_gwguard_cm}
mkdir -p "$GW_CM_DIR" 2>/dev/null
SSH() { command ssh -o ConnectTimeout=5 \
        -o ControlMaster=auto -o "ControlPath=$GW_CM_DIR/%r@%h:%p" -o ControlPersist=120 "$@"; }

# 임계값 — 초과하면 트립
# ── 부하 구조별 프로파일 (2026-09-09) ──────────────────────────────
# 왜: 같은 임계로 두 구조를 덮을 수 없다. **`c` 전체 CPU 가 구조에 따라 완전히 다르다.**
#   단일 세션 각 20 Mbps (2026-09-05)   max  53.9%
#   10지사 × 각 1 Mbps  (2026-09-09)   상시 68~93%  ← 초과 2,329건, 전부 오탐
# 10세션은 프로세스 10개 합 123% + WG 암복호 10개가 얹혀 머신 부하 자체가 다르다.
#
# multi 값의 근거 — 24시간 **정상** 런의 초과 샘플을 후보 임계에 재생해 얻은 최대 연속:
#   c:전체   임계 68 → 3연속 · **75 이상 → 1연속** (p50 77.1 · p90 87.3 · max 93.4)
#   c:1코어  임계 90~95 → 3연속 · 98 → 1연속        (p50 91.5 · max 100.0)
#   r:1코어  임계 95 → 3연속                        (인프라 컨테이너 버스트)
# → **수준이 아니라 지속성으로 가른다.** 78/95 에 streak 5 면 정상 런의 최대 연속(1·3)에
#   2배 이상 여유가 있고, 진짜 과부하는 수십 초~분 단위라 그대로 잡힌다.
#
# 이 프로파일은 `s` 의 apt(95 이상 4초)와 `r` 의 인프라 버스트(3초)도 통과시킨다 —
# **둘 다 우리 부하가 아니고 측정을 죽였을 뿐이므로 트립하지 않는 것이 맞다.**
# 검증 — 기록된 런을 가드 자신의 streak 카운터로 재생 (트립 = 연속 N회 도달)
#
#   런                    성격            구 62/85/3   single 68/90/3   multi 78/95/5
#   16M / 18M 정상        단일            통과         통과             통과
#   20M 32분 정상         단일            **트립(4)**  통과(1)          통과(1)
#   20M 1시간 정상 ×2     단일            통과(2)      통과(2)          통과(1~2)
#   22M 여유없음          단일            트립(4)      **트립(4)**      통과(1)
#   24M 붕괴              단일            트립(4)      **트립(4)**      통과(0)
#   18M 실패(08-07)       단일            트립(3)      **통과(2)**      통과(1)
#   다중 24시간 정상      10지사          트립(3)      **트립(3)**      **통과(2)**
#   다중 17시간 (s apt)   10지사          트립(6)      트립(6)          **통과(4)**
#
# ⚠️ **`multi` 를 단일 세션에 쓰지 말 것** — 24M 붕괴를 아예 못 잡는다(연속 0).
# ⚠️ **`single`(68/90) 은 08-07 18M 열화를 못 잡는다**(연속 2). 구 62/85 는 잡았다.
#    2026-09-05 재보정이 20M 오탐을 없앤 대가다. 그 사건은 09-02 에 재현되지 않았고
#    원인 미규명이며, 애초에 이 가드는 붕괴 탐지기가 아니다(손실은 수신측 계측으로 본다).
#
PROFILE=${GW_PROFILE:-single}
case "$PROFILE" in
  single) P_CPU_C=68; P_CORE=90; P_STREAK=3 ;;   # 2026-09-05 재보정. 붕괴/정상 분리 검증됨
  multi)  P_CPU_C=78; P_CORE=95; P_STREAK=5 ;;   # 2026-09-09 24시간 정상 런에서 도출
  *) echo "GW_PROFILE 은 single 또는 multi (받은 값: $PROFILE)" >&2; exit 2 ;;
esac

CPU_C=${GW_CPU_C:-$P_CPU_C}     # c 전체 busy % — 1차 판별자
CPU_VM=${GW_CPU_VM:-75}         # r·s 전체 busy % (VM, 여유 있음)
CORE=${GW_CORE:-$P_CORE}        # 어느 호스트든 가장 바쁜 1코어 busy % — 보조
LINK=${GW_LINK:-400}            # iface RX+TX Mbps — 증폭 루프 백스톱
STREAK=${GW_STREAK:-$P_STREAK}          # 연속 초과 횟수에서 트립 (단발 버스트 면역)

# 호스트별 테스트망 인터페이스
IF_C=${GW_IF_C:-enp2s0}
IF_R=${GW_IF_R:-ens18}
IF_S=${GW_IF_S:-ens18}

usage() { cat <<U
사용법:
  $0 precheck                   # 지표 전제가 아직 유효한지 확인 (트래픽 미발생)
  $0 sample                     # 세 호스트 부하 1회 출력
  $0 budget <세션당_양방향_Mbps> [세션수] [예산_논리CPU]   # 사전 판정 (용량 모델)
  $0 watch "<중단할 명령 패턴>"   # 초과 시 해당 프로세스를 죽이며 감시 (포그라운드)

임계값:  c 전체 ${CPU_C}%  ·  r·s 전체 ${CPU_VM}%  ·  최고 1코어 ${CORE}%  ·  링크 ${LINK} Mbps
         ${STREAK}회 연속 초과에서 트립, ${INTERVAL}초 간격
환경변수: GW_PROFILE(single|multi) GW_CPU_C GW_CPU_VM GW_CORE GW_LINK GW_STREAK GW_INTERVAL GW_KILL_HOSTS
         GW_IF_C GW_IF_R GW_IF_S GUARD_C GUARD_R GUARD_S
U
}

# ── 원격 1회 샘플 ────────────────────────────────────────────────
# 출력: "<전체busy%> <최고코어busy%> <iface Mbps> <코어수> <링크Mbps 또는 -1>"
#
# ⚠️ 두 시점을 **모두 원격에서 재고 경과시간도 원격 시계로** 계산한다.
# 2026-08-03: 예전 구현은 `ssh → sleep N → ssh` 후 N 으로 나눴다. ssh 왕복(~0.6s)이
# 경과에 더해지는데 분모는 N 이라 1초 창에서 1.6배 과대보고했고, 그 허위 초과로
# 워치독이 트립해 자식 multi-fec 을 고아로 남겼다. 그 고아들이 SO_REUSEPORT 로
# 다음 런의 포트를 나눠 가져 세션 절반이 조용히 죽는 오염을 세 번 만들었다.
probe() {  # $1=host $2=iface
  SSH "$1" "
    A=\$(grep -E '^cpu[0-9]+ ' /proc/stat)
    NA=\$(awk -v i='$2:' '\$1==i{print \$2+\$10}' /proc/net/dev)
    T0=\$(date +%s.%N)
    sleep $INTERVAL
    B=\$(grep -E '^cpu[0-9]+ ' /proc/stat)
    NB=\$(awk -v i='$2:' '\$1==i{print \$2+\$10}' /proc/net/dev)
    T1=\$(date +%s.%N)
    SP=\$(cat /sys/class/net/$2/speed 2>/dev/null || echo -1)
    printf '%s\n---\n%s\n' \"\$A\" \"\$B\" | awk -v t0=\$T0 -v t1=\$T1 -v na=\$NA -v nb=\$NB -v sp=\$SP '
      /^---\$/ { second=1; next }
      /^cpu/ {
        # busy = user+nice+system+irq+softirq+steal   (idle·iowait 제외)
        busy = \$2+\$3+\$4+\$7+\$8+\$9
        tot  = busy + \$5 + \$6
        if (!second) { b0[\$1]=busy; t0c[\$1]=tot }
        else         { b1[\$1]=busy; t1c[\$1]=tot; n++ }
      }
      END {
        sb=0; st=0; mx=0
        for (k in b1) {
          db=b1[k]-b0[k]; dt=t1c[k]-t0c[k]
          if (dt<=0) continue
          p=db/dt*100; sb+=db; st+=dt
          if (p>mx) mx=p
        }
        d=t1-t0; if (d<=0) d=$INTERVAL
        printf \"%.1f %.1f %.2f %d %d\", (st>0? sb/st*100 : 0), mx, (nb-na)*8/d/1e6, n, sp
      }'" 2>/dev/null
}

iface_of() { case "$1" in c) echo "$IF_C";; r) echo "$IF_R";; *) echo "$IF_S";; esac; }
host_of()  { case "$1" in c) echo "$C";;    r) echo "$R";;    *) echo "$S";;    esac; }
cpulim_of(){ case "$1" in c) echo "$CPU_C";; *) echo "$CPU_VM";; esac; }

probe_all() {  # $1=출력 디렉터리
  probe "$C" "$IF_C" > "$1/c" &
  probe "$R" "$IF_R" > "$1/r" &
  probe "$S" "$IF_S" > "$1/s" &
  wait
}

# ── precheck: 지표의 전제가 아직 성립하는가 ─────────────────────
# 두 사고의 원인이 "토폴로지가 바뀌어 지표가 무효해진 것" 이므로, 가드가 스스로
# 자기 전제를 확인한다. 트래픽을 만들지 않는다.
precheck() {
  local fail=0
  echo "[precheck] 호스트 도달성"
  for h in $C $R $S; do
    if SSH "$h" true 2>/dev/null; then
      echo "  ✓ $h"
    else
      echo "  ✗ $h 접속 실패"; fail=1
    fi
  done

  echo "[precheck] 인터페이스"
  for k in c r s; do
    h=$(host_of $k); i=$(iface_of $k)
    if SSH "$h" "test -d /sys/class/net/$i" 2>/dev/null; then
      echo "  ✓ $h $i"
    else
      echo "  ✗ $h 에 $i 없음 — GW_IF_* 를 고칠 것"; fail=1
    fi
  done

  # 데이터 경로가 온링크인가. gw 가 경로로 돌아오면 대역폭 지표가 다시 필요해진다.
  echo "[precheck] 데이터 경로 온링크 (gw 미통과 · 규칙 2)"
  for h in $C $R $S; do
    out=$(SSH "$h" 'v=0; n=0
      for ip in 192.168.100.141 192.168.100.85 192.168.100.86 192.168.100.84; do
        o=$(ip route get $ip 2>/dev/null | head -1)
        echo "$o" | grep -q " via " && v=$((v+1))
        echo "$o" | grep -qE "starlink|tun|wg" && n=$((n+1))
      done; echo "$v $n"' 2>/dev/null)
    set -- ${out:-9 9}
    if [ "$1" = 0 ] && [ "$2" = 0 ]; then
      echo "  ✓ $h  gw경유 0 · 터널경유 0"
    else
      echo "  ✗ $h  gw경유 $1 · 터널경유 $2"
      [ "$1" != 0 ] && echo "      → gw 가 경로에 있다. CPU 지표만으로는 부족하다 (대역폭 지표 필요)."
      [ "$2" != 0 ] && echo "      → 규칙 2 위반. 증폭 루프 위험 — 부하를 시작하지 말 것."
      fail=1
    fi
  done

  if [ $fail = 0 ]; then echo "[precheck] 통과"; else echo "[precheck] 실패 — 위 항목을 먼저 해결할 것"; fi
  return $fail
}

# ── sample: 세 호스트 동시 측정 ──────────────────────────────────
sample() {
  local tmp; tmp=$(mktemp -d); probe_all "$tmp"
  for k in c r s; do
    lim=$(cpulim_of $k)
    tot=""; read -r tot mx mbps n sp < "$tmp/$k" 2>/dev/null || true
    if [ -z "$tot" ]; then
      printf "  %-2s %-26s 측정 실패\n" "$k" "$(host_of $k)"; continue
    fi
    if [ "${sp:--1}" -gt 0 ] 2>/dev/null; then
      link=$(awk -v m=$mbps -v s=$sp 'BEGIN{printf "%.1f%% of %dM", m/s*100, s}')
    else
      link="속도불명(virtio)"
    fi
    printf "  %-2s 전체 %5.1f%%/%2d%%   최고1코어 %5.1f%%/%2d%%   %-7s %7.2f Mbps (%s)  코어%s\n" \
      "$k" "$tot" "$lim" "$mx" "$CORE" "$(iface_of $k)" "$mbps" "$link" "$n"
  done
  rm -rf "$tmp"
}

# ── 초과 판정: 사유 문자열 출력 (없으면 빈 문자열) ───────────────
check_over() {
  local tmp; tmp=$(mktemp -d); probe_all "$tmp"
  local why=""
  for k in c r s; do
    lim=$(cpulim_of $k)
    tot=""; read -r tot mx mbps n sp < "$tmp/$k" 2>/dev/null || true
    [ -z "$tot" ] && continue
    awk -v v="$tot"  -v l="$lim"  'BEGIN{exit !(v>l)}' && why="$why ${k}:전체=${tot}%>${lim}%"
    awk -v v="$mx"   -v l="$CORE" 'BEGIN{exit !(v>l)}' && why="$why ${k}:1코어=${mx}%>${CORE}%"
    awk -v v="$mbps" -v l="$LINK" 'BEGIN{exit !(v>l)}' && why="$why ${k}:링크=${mbps}Mbps>${LINK}"
  done
  rm -rf "$tmp"
  echo "$why"
}

case "${1:-}" in
  precheck) precheck ;;

  sample)
    echo "[sample] $(date +%H:%M:%S)  창 ${INTERVAL}s"
    sample ;;

  budget)
    # 사용: budget <세션당 양방향 Mbps> [세션수] [예산 논리CPU]
    #
    # ⚠️ RR 은 **양방향** 앱 Mbps 다 (용량 모델의 단위). 각 방향 4 Mbps 면 RR=8.
    # 예전 gw 버전은 "각 방향" 을 받았으니 호출부를 옮길 때 단위를 반드시 확인할 것.
    RR=${2:?세션당 양방향 앱 Mbps}; NS=${3:-1}; BUD=${4:-2.0}
    awk -v r=$RR -v ns=$NS -v bud=$BUD 'BEGIN{
      sr   = r*ns
      cost = ns*0.0181 + 0.1067*sr
      pct  = cost/4*100
      printf "세션 %d × 양방향 %.2f Mbps  (ΣR = %.2f Mbps)\n", ns, r, sr
      printf "  ① 총량  비용 %.2f / 예산 %.2f 논리CPU  → c 전체 busy 약 %.0f%%\n", cost, bud, pct
      printf "  ② 개별  R %.2f / 15.9 Mbps\n", r
      printf "  ③ NIC   ΣR %.2f / 31.25 Mbps 양방향\n", sr
      bad=0
      if (cost > bud) { printf "  ✗ ① 총량 초과 — 세션수나 레이트를 낮출 것\n"; bad=1 }
      if (r > 15.9)   { printf "  ✗ ② 단일 스레드 상한 초과 — 세션을 쪼갤 것\n"; bad=1 }
      if (sr > 31.25) { printf "  ✗ ③ NIC 단일 큐 상한 초과 (수신 softirq cpu2 고정)\n"; bad=1 }
      if (bad) exit 1
      printf "  ✓ 안전 (총량 여유 %.2f 논리CPU)\n", bud-cost
      printf "\n  ⚠️ 이 모델은 12 Mbps 한 점의 선형 외삽이고 미확정 요소가 전부 불리한 방향이다.\n"
      printf "     첫 30초는 저레이트로 올려 `sample` 실측과 대조한 뒤 목표로 갈 것.\n"
    }' ;;

  watch)
    PAT=${2:?중단할 프로세스 패턴}
    # 가드가 자기 전제부터 확인한다. 전제가 깨졌으면 감시를 시작하지 않는다 —
    # 무효한 지표로 "감시 중" 이라고 표시하는 것이 두 사고의 구조였다.
    if ! precheck; then
      echo "[guard] precheck 실패 → 감시를 시작하지 않는다. 부하도 시작하지 말 것."
      exit 3
    fi
    echo "[guard] 감시 시작 (프로파일 $PROFILE) — c ${CPU_C}% · r·s ${CPU_VM}% · 1코어 ${CORE}% · 링크 ${LINK}Mbps"
    echo "[guard] ${STREAK}회 연속 초과에서 '$PAT' 중단"
    streak=0
    while true; do
      why=$(check_over)
      # 단발 버스트(경로 probe·window 방출·FEC flush)로 죽지 않도록 연속 초과에서만 트립.
      # 2026-08-03: 1회 트립으로 1시간 런이 시작 직후 죽었다.
      if [ -n "$why" ]; then
        streak=$((streak+1))
        echo "[guard] $(date +%H:%M:%S) 초과($streak/$STREAK):$why"
      else
        streak=0
      fi
      if [ "$streak" -ge "$STREAK" ]; then
        echo "[guard] $(date +%H:%M:%S) 트립 →$why  → '$PAT' 중단"
        # ⚠️ 부모만 죽이면 자식 multi-fec 이 고아로 남아 리슨 포트를 계속 잡는다.
        # 2026-08-03: 그 고아 8개가 이후 런의 포트를 SO_REUSEPORT 로 나눠 가져
        # 세션 절반이 조용히 죽는 현상을 만들었다. 자식까지 확실히 정리한다.
        # ⚠️ 원격 kill 은 **bracket 패턴**을 써야 한다.
        # 2026-08-03: ssh 커맨드라인에 패턴 문자열이 그대로 들어 있어
        # `pgrep -f "$PAT"` 가 **그 셸 자신**을 매치했다. 루프가 자기를 kill -9 하면
        # 뒤따르는 `pkill -9 -f` 가 실행되지 않아 **정작 부하가 살아남는다.**
        # 가드가 부하를 못 멈추는 것은 가드가 없는 것과 같다 (800 Mbps 사고와 같은 구조).
        BPAT="[${PAT:0:1}]${PAT:1}"
        # ⚠️ bracket 패턴은 **원격 셸만** 보호한다. 이 스크립트의 argv 에는 패턴이
        # 평문(`watch mfguardtest`)으로 들어 있어 `pgrep -f "[m]fguardtest"` 가
        # **자기 자신을 매치한다.** 그러면 아래 로컬 루프가 자기를 kill -9 하고
        # 뒤따르는 원격 kill 이 실행되지 않아 정작 부하가 살아남는다.
        # 2026-08-05 에 실측으로 확인하고 조상 PID 제외를 추가했다.
        ANC="$$"; _p=$$
        while _p=$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' '); [ -n "$_p" ] && [ "$_p" != 0 ]; do
            ANC="$ANC $_p"
        done
        for p in $(pgrep -f "$BPAT"); do
            case " $ANC " in *" $p "*) continue;; esac   # 자기 자신·조상은 건너뛴다
            pkill -9 -P "$p" 2>/dev/null
            kill -9 "$p" 2>/dev/null
        done
        # pkill -9 -f 도 같은 이유로 자기를 죽일 수 있어 --older 대신 조상 제외 루프를
        # 이미 돌렸으므로 생략한다. 남은 것은 위 루프가 잡는다.
        for H in $KILL_HOSTS; do
            SSH "$H" "for p in \$(pgrep -f '$BPAT'); do
                    sudo pkill -9 -P \$p 2>/dev/null; sudo kill -9 \$p 2>/dev/null; done
                sudo pkill -9 -f '$BPAT' 2>/dev/null; exit 0" 2>/dev/null
        done
        exit 2
      fi
    done ;;

  *) usage; exit 1 ;;
esac
