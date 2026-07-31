# 다중 세션 테스트 결과 — 2026-06-19

multi-fec를 10개 동시 세션(session_id)으로 테스트한 결과 모음.

## 토폴로지

```
c.xdn(test3) 클라이언트 10개(=session_id 10개) ──▶ r.xdn 릴레이(192.168.100.85:4443)
                                              ──▶ s.xdn 서버(218.154.1.134:4443) ──▶ sink
운영(:443)과 분리된 평행 테스트 체인(:4443)으로 비침습 실행.
netem: s.xdn ens19 egress, delay 25±5ms / loss 15±25% (다운스트림에만 적용)
하베스트: aging_rt_server.py(s측), aging_rt_clients.py(c측)
```

## 1. 10세션 3시간 업스트림 아징 — `10session-3h-aging/`

mode1(RS) 90분 + mode2(RNLC) 90분. 세션당 50 pkt/s 태그 패킷, 60초 샘플링.

| 지표 | mode1 (RS) | mode2 (RNLC) | 판정 |
|------|-----------|--------------|------|
| 전달률 | 99.87% (2,606,601/2,610,059) | 99.84% (2,605,415/2,609,672) | ✅ |
| corrupt / cross-talk | 0 / 0 | 0 / 0 | ✅ 세션 격리 |
| 서버 생존 | crashed=False | crashed=False | ✅ |
| 클라 생존 | 10/10 | 10/10 | ✅ |
| RSS 누수 | 135.2→135.4MB (+0.21) | 145.3→145.5MB (+0.16) | ✅ 누수 0 |
| CPU | ~11% | ~10% | — |
| per-session 균형 | 각 ~260,650 | 각 ~260,550 | ✅ 균등 |

- `coordinator-full.log` — 3시간 전체 캡처(60초 샘플 타임라인 + RESULT)
- `server-mode{1,2}.log` — 서버 RSS/CPU/throughput 시계열
- `client-mode{1,2}.log` — 클라 sent/생존 시계열

> 측정 한계: netem 손실은 다운스트림(egress)에만 적용 → 이 업스트림 경로는
> 실손실 ~0.15%. 즉 이 run은 "다중 세션 서버 집계의 격리·안정성·무누수"를 검증.
> 다운스트림 FEC 복구는 아래 §2 참조.

## 2. 다운스트림 FEC 복구 — `downstream-fec/`

실제 WG `starlink-fec` 터널 위 `iperf3 -R`로 netem 15% 다운스트림 측정.

| 지표 | mode1 (RS) | mode2 (RNLC) |
|------|-----------|--------------|
| TCP goodput | 12.0 Mbit/s | 2.93 Mbit/s |
| UDP 잔여손실 | 0.0062% | 0.68% |

→ FEC가 15% 손실을 거의 완전 복구. RNLC는 RS 대비 goodput ~4배 낮음(디코드 병목).

- `downstream-results.md` — 상세 + raw 명령
- `iperf3-server.log` — iperf3 서버측 raw 로그

## 무효 판명된 접근 (참고)

합성 에코 왕복으로 다운스트림을 측정하려는 시도는 **무효**(FEC-on 53% < FEC-off
60%로 역전). 양방향 mud window·경로상태·FEC 그룹 타이밍이 결합돼 신호가 묻힘.
→ 실제 WG 터널 + iperf3가 정석. (스크립트 `*_bi.py`는 커밋 제외)

## 관련 커밋

- dev `b6b515e` — 하베스트(`test_scale_sessions.py`, `aging_rt_server.py`,
  `aging_rt_clients.py`) + CLAUDE.md 문서화
