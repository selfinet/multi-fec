# 패킷당 시스템 호출 줄이기 — 1.4.1-v2 vs perf 후보 (2026-10-22, 테스트망)

브랜치 `perf/syscall-batch` (v2 위, 미병합·미릴리스, 와이어 무변경):
- `0a0ccf5` WG 쪽 송신을 `sendmmsg` 묶음으로(`wg_batch`, ev_prepare·묶음 가득 시 flush, 지연·임의 손실 시 기존 경로)
- `0cff2d8` server 의 패킷마다 `recvfrom(MSG_PEEK)` 제거 — 출처·원본은 `mud_get_last_remote`/`mud_get_last_raw`(신설)
검증: 단위 10/10·7/7·11/11, 스위트 CLI 90·라우팅 9·다운스트림 24·RNLC 9·성능 26·세션 상한·만료 통과,
server 탐지 패킷 응답 1.4.0 과 같음(`probe_srv.py` 결과는 대화 기록 — 무작위·0x45 → QUIC Initial, TLS형·0xC1·20 B → 무응답).

측정 `perfab.sh`: c·s 만 교체(r 1.4.0), 가드 선기동, tunnel_regress.sh steady 15·20 Mbps ×2, strace 15 Mbps ×1. 끝나고 c·s 1.4.0 복원.

| 시스템 호출 /s (15 Mbps) | 1.4.1-v2 | perf |
|---|---|---|
| server 합계 | 5,708 | **3,200 (−44%)** |
| server recvfrom / sendto | 3,620 / 1,670 | 0 / 0 |
| server sendmmsg / recvmmsg | 148 / 184 | 914 / 1,683 |
| client 합계 | 3,195 | 3,095 (−3%) |
| client sendto | 1,324 | 0 |
| strace 중 손실 상/하 | 0.45 / 3.95% | 0 / 0% |

| multi-fec CPU 중앙값 (strace 없음) | 15 Mbps | 20 Mbps |
|---|---|---|
| server 1.4.1-v2 (rep1) | 46.8% | 53.3% |
| server perf (rep1/rep2) | 43.3 / 44.0% | 51.2 / 49.2% |
| client 1.4.1-v2 (rep1) | 47.8% | 55.9% |
| client perf (rep1/rep2) | 47.4 / 46.8% | 55.6 / 53.0% |

1.4.1-v2 rep2 는 손실·EAGAIN 으로 트래픽이 줄어(if 83·107 vs 104·135 Mbps) CPU 비교에서 뺐다.

**판단**: server 시스템 호출 −44% → CPU −2~4%p(상대 6~8%). 커널 UDP 처리는 남는다. client 는 이벤트 루프가 자주 깨어 묶음당 패킷이 적어
호출 합계·CPU 거의 같음. 손실은 perf 4구간 0(1.4.1-v2 rep2 0.15~0.7%) — n 작아 확정 아님.
J1900 지사 상한(~15 Mbps)을 의미 있게 올리지는 못한다(추정). 본사 server 는 지사 합산이라 server 쪽 절감이 누적된다.
