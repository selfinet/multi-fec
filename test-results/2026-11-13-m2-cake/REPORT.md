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
- ⚠️ **재시작마다 터널 복귀 16.0초**(2회 모두). 첫 시도는 3초 대기 후 실패로 끝나 하네스를 고쳐 재실행했다. 원인 미조사(WG 핸드셰이크 재시도 주기·multi-fec 측 새 소스 포트 가능성). rate 만 바꿀 땐 재시작 대신 `tc qdisc change dev wg0 root cake bandwidth …`.

## 원복
양쪽 wg-test.conf 원본 복원(백업 `.bak-2026-11-13` 보존)·wg-quick 재시작·HTB 삭제 → client fq_codel / server mq, wg-test noqueue, 잔여 프로세스·iptables 없음, WG ping 정상, multi-fec 1.4.3 aa60be9f 그대로. sv1 운영 multi-fec-server PID 754·md5 3db3617e 불변.
