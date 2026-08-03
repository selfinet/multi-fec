#!/bin/bash
# mf_gwguard.sh — gw ens18 부하 감시·차단 (테스트망 전용). 모든 부하 하네스가 이걸 쓴다.
#
# 왜 필요한가 (2026-08-02 사고)
# ---------------------------------
# 기존 하네스는 대리지표로 **c 의 enp2s0** 를 썼다. 그런데 c↔r 은 동일 서브넷 온링크라
# **gw 를 지나지 않는다.** 즉 gw 부하를 재지 않으면서 "50 Mbps 안쪽"이라고 보고해 왔다.
# 우연히 두 값이 비슷해 오래 안 들켰다(c 회선 ≈ r↔s 회선).
#
# 올바른 지표
# ---------------------------------
#   gw ens18 은 c·r·s 가 모두 물린 포트다. 우리 트래픽 중 gw 를 지나는 것은 r↔s 홉뿐이고,
#   gw 는 그 패킷을 같은 포트로 되보낸다(헤어핀). 따라서:
#
#       gw ens18 우리 몫 (방향당)  =  s ens18 RX + s ens18 TX
#
#         r→s : gw 가 s 로 송신  = s 의 RX
#         s→r : gw 가 r 로 송신  = s 의 TX
#
#   실측 환산계수: 앱 1 Mbps 당 3.54 Mbps  (duplicate 2사본 × FEC 1.30 × obfs 패딩·헤더 1.36)
#   aggregate 로 바꾸면 사본이 1개라 절반(1.77)이 된다.
#
# 한도 (2026-08-02 사용자 지정)
# ---------------------------------
#   gw ens18 **방향당 70 Mbps**. 유휴 기저 23 Mbps 는 c/r/s 가 아닌 타 장비 몫이라
#   우리 가용은 47 Mbps → 앱 총 13.3 Mbps(각 방향 6.6). 아래 기본값은 여기서 유도했다.
#
#   ⚠️ 기저는 고정이 아니다. 2026-08-02 01:30·05:20 에 gw 가 200 Mbps 까지 갔는데
#      그중 우리 몫은 45 뿐이었다. 타 장비가 튀면 우리 예산과 무관하게 한도를 넘을 수 있으니
#      장시간 런에서는 기저를 주기적으로 다시 재는 편이 좋다.
set -u
S=${S:-s.xdn.selfinet.com}
# 부하 생성기가 도는 호스트들. 워치독은 여기서도 죽여야 한다 —
# 2026-08-03: sv1 로컬에서만 pkill 해서 원격 부하가 안 죽고 무방비로 계속 돌았다.
KILL_HOSTS=${GW_KILL_HOSTS:-"c.xdn.selfinet.com r.xdn.selfinet.com s.xdn.selfinet.com"}
IFACE=${GW_IFACE:-ens18}
LIMIT=${GW_LIMIT:-70}          # gw ens18 방향당 한도
BASE=${GW_BASE:-23}            # 타 장비 기저 (유휴 실측)
TRIP=${GW_TRIP:-85}            # 가용분의 몇 %에서 죽일지
INTERVAL=${GW_INTERVAL:-1}
AVAIL=$(( LIMIT - BASE ))
KILL_AT=$(awk -v a=$AVAIL -v t=$TRIP 'BEGIN{printf "%.1f", a*t/100}')

usage() { cat <<U
사용법:
  $0 sample                     # 현재 우리 몫(Mbps) 1회 출력
  $0 budget <세션당_각방향_Mbps> [세션수] [fec-timeout] [MTU]   # 사전 판정
  $0 watch "<중단할 명령 패턴>"   # 초과 시 해당 프로세스를 죽이며 감시 (포그라운드)
환경변수: GW_LIMIT($LIMIT) GW_BASE($BASE) GW_TRIP($TRIP%) → 트립 $KILL_AT Mbps
U
}

sample() {  # → 우리 몫 Mbps
  # ⚠️ 반드시 **원격에서 두 시점을 모두 재고 경과시간도 원격 시계로** 계산한다.
  # 2026-08-03: 예전 구현은 `ssh → sleep N → ssh` 후 N 으로 나눴다. ssh 왕복(~0.6s)이
  # 경과에 더해지는데 분모는 N 이라 1초 창에서 1.6배 과대보고했고, 그 허위 초과로
  # 워치독이 트립해 자식 multi-fec 을 고아로 남겼다. 그 고아들이 SO_REUSEPORT 로
  # 다음 런의 포트를 나눠 가져 세션 절반이 조용히 죽는 오염을 세 번 만들었다.
  ssh $S "a=\$(awk -v i=\"$IFACE:\" '\$1==i{print \$2+\$10}' /proc/net/dev); t0=\$(date +%s.%N)
          sleep $INTERVAL
          b=\$(awk -v i=\"$IFACE:\" '\$1==i{print \$2+\$10}' /proc/net/dev); t1=\$(date +%s.%N)
          awk -v x=\$((b-a)) -v s=\$t0 -v e=\$t1 'BEGIN{d=e-s; if(d<=0)d=$INTERVAL; printf \"%.2f\", x*8/d/1e6}'" 2>/dev/null
}

case "${1:-}" in
  sample) echo "$(sample) Mbps  (한도 $LIMIT − 기저 $BASE = 가용 $AVAIL, 트립 $KILL_AT)" ;;
  budget)
    # 사용: budget <세션당 각방향 Mbps> [세션수] [fec-timeout ms] [MTU바이트]
    #
    # ⚠️ 상수 계수 3.54 를 쓰면 안 된다 (2026-08-02 실측으로 확인).
    # FEC 오버헤드는 그룹 크기 g 에 달렸고 g 는 **세션당 레이트**가 정한다:
    #     g = 1 + floor(pps x fec-timeout),  pps = R x 1e6 / (8 x MTU)
    # 6 Mbps/세션이면 g=7 -> 오버헤드 29% 지만, 0.6 Mbps/세션이면 g=1 ->
    # 데이터1+패리티1 = **오버헤드 100%** 다. 상수 계수는 저레이트 다세션에서
    # 항상 과소평가하고, 실제로 8세션x0.6 런에서 예측 34.0 vs 실측 44.3 (1.30배)
    # 으로 한도의 96% 까지 갔다.
    R=${2:?세션당 각 방향 Mbps}; NS=${3:-1}; FT=${4:-10}; MTU=${5:-1200}
    awk -v r=$R -v ns=$NS -v ft=$FT -v mtu=$MTU -v av=$AVAIL -v k=$KILL_AT -v lim=$LIMIT -v b=$BASE 'BEGIN{
      pps = r*1e6/(8*mtu)
      g   = 1 + int(pps*ft/1000); if (g>20) g=20
      # -f 5:1,20:4 보간 테이블
      y = (g<=5)?1:((g<=10)?2:((g<=15)?3:4))
      amp = (g+y)/g                    # FEC 증폭
      f   = amp * 2 * 1.36             # x duplicate 2사본 x obfs 패딩·헤더
      gw  = r * ns * 2 * f             # 양방향
      printf "세션 %d x 각 방향 %.2f Mbps  (g=%d, y=%d → FEC %.2fx, 계수 %.2f)\n", ns, r, g, y, amp, f
      printf "  gw 우리몫 %.1f, 총계 %.1f / 한도 %d (%.0f%%)\n", gw, gw+b, lim, (gw+b)/lim*100
      if (gw>av)      { printf "  ✗ 한도 초과 (가용 %.1f) — 실행 금지\n", av; exit 1 }
      else if (gw>k)  { printf "  △ 트립선(%.1f) 초과 — 레이트/세션수를 낮출 것\n", k; exit 1 }
      else              printf "  ✓ 안전 (여유 %.1f Mbps)\n", av-gw
    }' ;;
  watch)
    PAT=${2:?중단할 프로세스 패턴}
    echo "[gwguard] 감시 시작 — 트립 $KILL_AT Mbps (한도 $LIMIT, 기저 $BASE)"
    streak=0
    while true; do
      v=$(sample)
      over=$(awk -v v=$v -v k=$KILL_AT 'BEGIN{print (v>k)?1:0}')
      # 단발 버스트(경로 probe·window 방출)로 죽지 않도록 3회 연속에서만 트립한다.
      # 2026-08-03: 1회 트립으로 1시간 런이 시작 직후 죽었다.
      if [ "$over" = 1 ]; then streak=$((streak+1)); else streak=0; fi
      if [ "$streak" -ge 3 ]; then
        echo "[gwguard] $(date +%H:%M:%S) 초과 ${v} > ${KILL_AT} Mbps → '$PAT' 중단"
        # ⚠️ 부모만 죽이면 자식 multi-fec 이 고아로 남아 리슨 포트를 계속 잡는다.
        # 2026-08-03: 그 고아 8개가 이후 런의 포트를 SO_REUSEPORT 로 나눠 가져
        # 세션 절반이 조용히 죽는 현상을 만들었다. 자식까지 확실히 정리한다.
        # ⚠️ 원격 kill 은 **bracket 패턴**을 써야 한다.
        # 2026-08-03: 아래 ssh 커맨드라인에는 패턴 문자열이 그대로 들어 있어
        # `pgrep -f "$PAT"` 가 **그 셸 자신**을 매치했다. 루프가 자기를 kill -9 하면
        # 뒤따르는 `pkill -9 -f` 가 실행되지 않아 **정작 부하가 살아남는다.**
        # 가드가 부하를 못 멈추는 것은 가드가 없는 것과 같다(800 Mbps 사고와 같은 구조).
        # '[r]c_probe.py' 는 정규식으로 'rc_probe.py' 를 매치하지만, 이 문자열이 든
        # 커맨드라인에는 'rc_probe.py' 가 나타나지 않아 자기를 매치하지 않는다.
        BPAT="[${PAT:0:1}]${PAT:1}"
        # 로컬(ssh 래퍼 포함) — 자식까지
        for p in $(pgrep -f "$BPAT"); do
            pkill -9 -P "$p" 2>/dev/null
            kill -9 "$p" 2>/dev/null
        done
        pkill -9 -f "$BPAT" 2>/dev/null
        # 원격 — 부하 생성기는 c 에서 돌고 그 자식이 multi-fec 이다.
        # 부모만 죽이면 자식이 고아가 되어 SO_REUSEPORT 로 다음 런의 포트를
        # 나눠 가지므로 세션 절반이 조용히 죽는다(2026-08-03 실제 발생).
        for H in $KILL_HOSTS; do
            ssh -o ConnectTimeout=5 "$H" "for p in \$(pgrep -f '$BPAT'); do
                    sudo pkill -9 -P \$p 2>/dev/null; sudo kill -9 \$p 2>/dev/null; done
                sudo pkill -9 -f '$BPAT' 2>/dev/null; exit 0" 2>/dev/null
        done
        exit 2
      fi
    done ;;
  *) usage; exit 1 ;;
esac
