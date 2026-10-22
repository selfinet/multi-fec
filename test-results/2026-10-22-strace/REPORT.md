# 패킷당 시스템 호출 측정 — strace (2026-10-22, 테스트망, 1.4.0)

`strace_run.sh`: 가드 선기동, WG 위 mfgen 양방향 15 Mbps 60초, 20초째부터 15초 c·s multi-fec 에 `strace -c -f`.
바이너리·유닛 무변경. strace 가 붙으면 처리가 느려지므로(그 구간 하향 손실 13%) **호출 횟수·비율만** 쓴다.
그 구간 앱 패킷: 상향 1,552 pps · 하향 717 pps. c·s 에 `strace` 패키지 설치(사용자 승인, 남겨 둠).

| server (초당 ~5,440) | 초당 | 시간 비중 | 의미 |
|---|---|---|---|
| recvfrom | 3,584 | 42% | mud 수신 전 출처 엿보기 `MSG_PEEK` (`mf_server.cpp:1051`) — 수신 패킷마다 |
| sendto | 1,556 | 41% | WG 전달 `delay_send`→`my_send` — 앱 패킷마다 |
| recvmmsg | 168 | 8% | mud 묶음 수신 |
| sendmmsg | 59 | 8% | mud 묶음 송신 |

| client (초당 ~2,980) | 초당 | 시간 비중 | 의미 |
|---|---|---|---|
| sendmmsg | 789 | 47% | mud 묶음 송신(묶음당 ~5) |
| recvmmsg | 761 | 20% | WG·mud 묶음 수신 |
| sendto | 701 | 18% | WG 전달 — 하향 앱 패킷마다 |
| epoll_wait | 700 | 15% | |

개선 후보: ① server `MSG_PEEK` 제거(출처는 `mud_get_last_remote()`) → 초당 ~3,600회(66%) 감소,
② WG 쪽 송신을 `sendmmsg` 묶음으로 → server ~1,550·client ~700회/s 를 묶음 단위로. 와이어 무변경.
CPU 감소폭은 이 측정으로 알 수 없다 — 개선 전후 multi-fec CPU 비교 또는 `perf` 로 확인할 것.
