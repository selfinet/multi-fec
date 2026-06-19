# RNLC mode2 다운스트림 격차 분석 (2026-06-19)

다운스트림에서 RNLC(mode2) TCP goodput이 RS(mode1)의 ~1/4 (2.93 vs 12.0 Mbps,
`downstream-results.md`). 처음엔 "클라(Atom) 가우스 소거 디코드 병목"으로 추정했으나,
측정값 재검산 결과 **원인을 정정**한다.

## ⚠️ 정정: 디코드 CPU는 원인이 아니다

| | mode1 (RS) | mode2 (RNLC) |
|--|--|--|
| UDP `-b 8M` 실통과 | 8.02 Mbps | **7.96 Mbps** (거의 풀) |
| UDP 잔여손실 | 0.0062% | **0.68%** |
| TCP goodput | 12.0 Mbps | 2.93 Mbps |

- mode2가 UDP 8Mbit/s를 거의 다 통과시켰다 → throughput 천장은 최소 8Mbit/s,
  TCP goodput(2.93)보다 훨씬 위. **CPU가 TCP를 막은 게 아니다.**
- 가우스 소거 연산량: 손실 3/20, symlen~1350일 때 ≈ 90 muladd × 1350 ≈ 0.12M byte-op/세대.
  8Mbit/s(~37세대/s)에서 ≈ 4.5M byte-op/s — Atom에서도 사소. 디코드 CPU는 한계가 아님.
- **TCP 4배 격차는 잔여손실(0.68% vs 0.006%, 100배)이 원인.** TCP BW ∝ MSS/(RTT·√p)
  이므로 √(0.0068)/√(0.00006) ≈ 10배 차이가 goodput을 끌어내림.

## 진짜 원인: 랜덤 계수의 rank 결핍 (비-MDS)

`rnlc.cpp:212-214` — 코딩 패킷 계수가 순수 난수:
```c
unsigned char *coeff = (unsigned char *)(o + idx);
for (int c = 0; c < k; c++)
    coeff[c] = (unsigned char)(get_fake_random_number() & 0xFF);   // 랜덤
```

- RS는 Vandermonde 기반 **MDS**: 임의의 k개 수신 → **항상** 복구.
- 랜덤 GF(256) 계수는 수신 코딩 패킷들이 **1차 종속일 확률**이 있다. 여유분(받은
  코딩 수)이 손실 수와 같을 때 full-rank 확률 ≈ ∏(1−256⁻ⁱ) → 실패 ≈ 0.4%.
  계수가 0이 나오거나 두 코딩 패킷이 종속이면 손실 ≤ r 인데도 복구 실패.
- 이 실패가 잔여손실로 누적 → 관측 0.68%와 동일 수준. RS(0.006%)와의 100배 격차 설명.

## 수정: 계수를 MDS(Cauchy)로

디코더(`try_decode`, `:437-548`)는 계수를 wire에서 읽어 일반 가우스 소거하므로
**인코더 계수 생성만 바꾸면 된다**(디코더 무변경).

Cauchy 행렬 P[j][c] = 1/(x_j ⊕ y_c), x_j = k+j (코딩 r행), y_c = c (k열).
x·y 범위가 분리돼 x_j⊕y_c ≠ 0 보장 → gf_inv 정의됨. systematic [I|P]에서 P가
Cauchy면 모든 정방 부분행렬이 가역 → **MDS** → RS와 동일하게 임의 k개 수신 시 복구 보장.
(전제: k+r ≤ 255. 초과 시 가드 후 랜덤 폴백.)

기대 효과: rank-결핍성 잔여손실 제거 → mode2 TCP goodput이 RS 수준에 근접.

## 부차적(이번 격차의 주범 아님)

- `rnlc_gf_muladd`(`:48-55`) 스칼라+데이터의존분기, SIMD 없음 — 고대역폭(수십 Mbps)
  에선 의미 있으나, 본 다운스트림(저~중속, 손실 지배)에서는 throughput 한계 아님.
- `try_decode`가 size≥k에서 rank 부족 시 전체 재계산(`:516`) — 보통 1회로 끝나
  현 시나리오 영향 작음.
- 위 둘은 후순위. 본 격차의 해결은 **MDS 계수**가 핵심.

## 검증 계획
1. 인코더 Cauchy 계수 적용
2. `test_rnlc_unit` 11케이스 (encode→임의드롭→decode) 회귀 — 최대손실 복구가
   이제 **결정적으로** 통과해야 함
3. (가능 시) 다운스트림 재측정으로 mode2 TCP goodput 개선 확인

## 참고
- 측정: `downstream-results.md`, `iperf3-server.log`
- 코드: `rnlc.cpp` (계수 생성 `:212-214`, `try_decode` `:437-548`)
