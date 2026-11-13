# CAKE(wg-quick PostUp) PC별 공평 분배 — mini 실장비 (2026-11-13)

**질문**: WG 아래 PC 한 대가 터널을 포화시키면 다른 PC가 느려진다. wg 인터페이스에 CAKE 를 걸면 막히는가?

## 구성
- mini: client-test(.2.90, Atom N2600) ↔ test-server(.2.91, J4125), multi-fec 1.4.3(aa60be9f) duplicate, 2경로(enp3s0 직결 / enp4s0 릴레이 경유).
- 병목: 경로마다 multi-fec UDP 만 HTB 10 Mbit(pfifo 100) — 11-12 aggtest 와 같은 방식. 보정 실측 앱 처리량 상향 7.27 / 하향 6.81 Mbps.
- PC 흉내: 터널 안 IP 2개(런타임) — A 10.9.31.11 = iperf3 TCP 8연결, B 10.9.31.12 = ping 0.2초 + iperf3 TCP 1연결. 60초, 방향별 CAKE 없음/있음 × 2회.
- CAKE: `PostUp = tc qdisc replace dev %i root cake bandwidth 5785kbit {dual-srchost|dual-dsthost} besteffort`
  (client = dual-srchost 업로드, server = dual-dsthost 다운로드, rate = 보정 최소값 × 0.85).
- 하네스 `caketest.py`, 원자료 `results.jsonl`·`run.log`·`full*.out`. 가드(client 85%·server 88%·코어 95%) 트립 0.

## 결과 (2회 평균, 2회 값 차이 작음)

| 방향 | CAKE | A Mbps | B Mbps | B 몫 | B ping p50 / p99 | B ping 손실 |
|---|---|---|---|---|---|---|
| 업로드 | 없음 | 6.59 | 0.81 | 11 % | **114 / 125 ms** | 4.5~5.2 % |
| 업로드 | 있음 | 3.13 | 2.60 | **45 %** | **3.2 / 6.1 ms** | 0 % |
| 다운로드 | 없음 | 5.86 | 1.18 | 17 % | **108 / 119 ms** | 1.1~1.9 % |
| 다운로드 | 있음 | 3.04 | 2.67 | **47 %** | **3.1 / 6.4 ms** | 0 % |

무부하 ping 2.4 ms. multi-fec EAGAIN 0, client 최고 코어 50~58 %.

## 해석
- CAKE 없이는 병목 큐(pfifo 100 ≈ 110 ms)를 A 가 채워 B 의 지연이 +110 ms, 대역은 연결 수 비례(8:1 에 가까움).
- CAKE 를 걸면 큐가 CAKE 안으로 옮겨져 B 는 무부하 수준 지연(+1 ms)·거의 반반 분배. 연결 수와 무관하게 호스트 단위로 나뉜다(dual-*host).
- 대가: 합계 처리량 7.4 → 5.7 Mbps(rate 를 실측의 85 %로 둔 몫). rate 를 올리면 회선이 병목으로 돌아가 효과가 사라진다 — 이 균형점은 측정하지 않았다.
- 다운로드는 **보내는 쪽(server wg 송신)** 에 dual-dsthost 로 걸어 효과를 봤다. 지사가 PC 를 NAT 하면 server 에서 PC 가 구분되지 않으므로 이 결과는 라우팅 구성에만 해당한다(미검증).

## PostUp 동작
- wg-quick 재시작 2회 모두 CAKE 가 자동으로 다시 걸렸다.
- ⚠️ **재시작마다 터널 복귀 16.0초**(2회 모두). 첫 시도는 3초 대기 후 실패로 끝나 하네스를 고쳐 재실행했다. 원인은 WireGuard 재핸드셰이크 타이머(아래 후속 1, multi-fec 무관). rate 만 바꿀 땐 재시작 대신 `tc qdisc change dev wg0 root cake bandwidth …`.

## 원복
양쪽 wg-test.conf 원본 복원(백업 `.bak-2026-11-13` 보존)·wg-quick 재시작·HTB 삭제 → client fq_codel / server mq, wg-test noqueue, 잔여 프로세스·iptables 없음, WG ping 정상, multi-fec 1.4.3 aa60be9f 그대로. sv1 운영 multi-fec-server PID 754·md5 3db3617e 불변.

---

## 후속 1 — wg-quick 재시작 16초 단절의 원인 (13:13~13:18, `restart.py`, `restart.jsonl`·`restart.out`)

부하·셰이핑 없이 재시작 대상별 2회. client 에서 0.2초 ping·`latest-handshakes`, 양쪽 lo(WG↔multi-fec) tcpdump.

| 재시작 | 터널 복귀 | 관찰 |
|---|---|---|
| client 만 | 0.96 / 1.03 s | 재시작 직후 핸드셰이크(148→92 B) 즉시 성공 |
| server 만 | 16.3 / 15.6 s | server 측 세션 소멸, client 는 15.5~16 s 뒤에야 새 핸드셰이크 |
| 양쪽(client→server 순) | 16.3 / 17.1 s | 0.6 s 핸드셰이크 성공 → 직후 server 재시작이 무효화 → 16 s 뒤 재시도 |

- 핸드셰이크 패킷은 client lo 와 server lo 에 **같은 시각**(±10 ms)에 찍혔다 — **multi-fec 은 지연 없이 전달**했다.
- 원인은 WireGuard 타이머: server WG 가 새로 뜨면 키가 없어 client 의 기존 키 패킷을 조용히 버리고, client 는
  "보냈는데 못 받음"이 KEEPALIVE_TIMEOUT(10 s)+REKEY_TIMEOUT(5 s) 지나야 재핸드셰이크한다 — 측정 15.5~16.3 s 와 일치.
- 대응: server WG 재시작 뒤 client WG 도 재시작(1 s), CAKE rate 변경은 재시작 대신 `tc qdisc change`. 서버 재부팅도 같은 15 s 를 겪는다(WG 고유).

## 후속 2 — CAKE rate 한계 (13:18~13:36, `sweep.out`, results.jsonl `kind=sweep`)

같은 조건 재보정: 상향 7.34 / 하향 6.86 Mbps(TCP 8연결 실측). rate = 방향별 실측 × %. 각 1회.

| 방향 | rate | 합계 Mbps | B 몫 | B ping p50 / p99 | B ping 손실 |
|---|---|---|---|---|---|
| 업로드 | 없음 | 7.33 | — ¹ | 114 / 127 ms | 3.3 % |
| 업로드 | 85 % | 6.19 | 45 % | 3.1 / 5.5 ms | 0 |
| 업로드 | 90 % | 6.56 | 46 % | 3.2 / 5.5 ms | 0 |
| 업로드 | 95 % | 6.94 | 46 % | 3.5 / 8.6 ms | 0 |
| 업로드 | **100 %** | 7.19 | 42 % | **115 / 118 ms** | 0.37 % |
| 업로드 | 105 % | 7.52 | 40 % | 116 / 126 ms | 0.37 % |
| 다운로드 | 없음 | 7.02 | 17 % | 107 / 119 ms | 3.0 % |
| 다운로드 | 85 % | 5.76 | 47 % | 3.1 / 6.6 ms | 0 |
| 다운로드 | 90 % | 6.08 | 47 % | 3.1 / 6.3 ms | 0 |
| 다운로드 | 95 % | 6.42 | 47 % | 3.0 / 6.4 ms | 0 |
| 다운로드 | 100 % | 6.79 | 46 % | 3.0 / 5.6 ms | 0 |
| 다운로드 | **105 %** | 6.78 | 38 % | **114 / 125 ms** | 0.37 % |

¹ B 의 iperf3 결과가 기록되지 않음(첫 시험에서 같은 조건 B 몫 10~11 %).

- 지연 보호의 경계는 **실측 처리량의 95~100 %(상향) / 100~105 %(하향)** 이다. 넘으면 큐가 다시 회선(HTB pfifo)으로 가 지연이 무보호 수준(~115 ms)으로 돌아간다.
  대역 분배는 경계를 넘어도 일부 남는다(40~42 %) — 지연 보호가 먼저 사라진다.
- 경계가 날카롭다(95 % 3.5 ms → 100 % 115 ms). 실제 회선은 용량이 흔들리므로 **권장 90 %** — 85 % 대비 처리량 +6 %, 지연 동일.
- "실측"은 TCP 8연결 goodput 이다. 회선·FEC 설정이 바뀌면 다시 재야 한다.
