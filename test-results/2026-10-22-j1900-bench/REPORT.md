# J1900(지사 장비) vs 테스트망 VM — multi-fec 기준 코어 속도 (2026-10-22)

도구: `tools/bench/mf_bench` (정적, 단일 스레드, 루프백만, 약 12초, sha256 `4e10e27a32240fc0…`).
J1900 측정은 사용자가 DJ19M 에서 직접 실행했다(이 세션은 서비스 장비에 접속하지 않았다). VM 은 테스트망 c(`QEMU Virtual CPU 2.5+`, 2 vCPU, ~2.0 GHz).

| 항목 | VM c | J1900 (DJ19M, Celeron J1900 @1.99 GHz) | VM ÷ J1900 |
|---|---|---|---|
| RS 인코드 20+4 ×1350 B | 204.6 MB/s | 96.2 MB/s | 2.13 |
| RS 복구 (4 손실) | 203.7 MB/s | 94.8 MB/s | 2.15 |
| 루프백 UDP send+recv 1350 B | 90,387 pkt/s | 47,154 pkt/s | 1.92 |
| obfs encode / decode | 4.51M / 3.76M pkt/s | 2.48M / 2.16M pkt/s | 1.82 / 1.74 |
| memcpy 1350 B | 14,636 MB/s | 8,476 MB/s | 1.73 |
| (참고) openssl ChaCha20-Poly1305 1 KB | 429 MB/s | 197 MB/s | 2.18 |
| (참고) openssl SHA-256 1 KB | 117 MB/s | 86.5 MB/s | 1.36 |

**multi-fec 핫패스(FEC·UDP) 기준 J1900 은 약 2배 느리다.**

## 처리 한계 추정 (VM c 실측 × 2.0)

VM c 의 multi-fec 프로세스 CPU(1코어=100%)는 `test-results/2026-10-22-v2-tunnel/raw/*/hs_c.csv`(duplicate, 양방향, 1.4.0·v2 동일):
15 Mbps 중앙 33~37%(p90 38~41%), 20 Mbps 45~46%(p90 51~52%).

| duplicate 양방향 각 | J1900 추정 multi-fec CPU | 판단 |
|---|---|---|
| 10 Mbps | ~47% | 여유 |
| 15 Mbps | ~70% (p90 ~80%) | 가능, 여유 작음 |
| 20 Mbps | ~90% (p90 100%+) | 단일 코어 포화 — 손실 위험 |
| aggregate 40 Mbps | 150%+ (추정) | 사실상 불가 |

multi-fec 은 단일 스레드라 J1900 의 4코어는 이 한계를 올리지 못한다(WireGuard 는 커널이 여러 코어로 처리).
선형 비례 가정의 추정이다 — 확정은 J1900 급으로 늦춘 VM 또는 J1900 실장비 계단 시험으로.
