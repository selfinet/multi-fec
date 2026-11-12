# duplicate vs aggregate — 경로별 속도 제한 10 Mbit/s (mini 테스트망, 2026-11-12)

하네스 `aggtest.py`(`2026-11-12-m2-v143b/m2test.py` 복사 + 단계 `shape_on`·`shapecheck`·`dupagg`·`aggcut`), 원자료 `results.jsonl`·`run.log`·`full.out`.
23:16~23:46 UTC, 사용자 승인. 바이너리 1.4.3b(86e6683, sha256 `253ae751…`)·1.4.1(`0ec4d839…`). 각 단계 1회.

## 조건
- 두 호스트의 enp3s0·enp4s0 에 HTB `rate 10mbit ceil 10mbit burst 15k` + pfifo 100, u32 필터로 **각 경로의 multi-fec UDP 만** 제한
  (path0 상향 dst .91:443 · 하향 sport 443 → .90, path1 상향 dst 172.30.4.1:8443 · 하향 sport 8443 → 172.30.4.2). ssh 등은 무제한 기본 클래스.
- 모드는 client·server 둘 다 drop-in `--multipath-mode aggregate`(하향은 server 모드를 따른다). relay 무변경. 실행 중 cmdline 으로 확인.
- 부하: mfgen 양방향 4~16 Mbps(2 단위), 단계 60초, WG 안쪽. 가드 client 85%·server 88%·코어 95%.

## 앱 손실 (상향/하향 %)
| Mbps | 1.4.3b duplicate | 1.4.3b aggregate | 1.4.1 aggregate |
|---|---|---|---|
| 4 | 0 / 0 | 0 / 0 | 0 / 0 |
| 6 | 0 / 0 | 0 / 0 | 0 / 0 |
| 8 | 0.39 / 0.02 | 0 / 0 | 0 / 0 |
| 10 | 10.1 / 5.8 | 0 / 0 | 0 / 0 |
| 12 | 25.4 / 23.7 | 0 / 0 | 0 / 0 |
| 14 | 36.4 / 34.5 | 5.66 / 0.49 | 2.31 / 0.53 |
| 16 | 43.2 / 42.7 | 11.5 / 5.4 | 9.4 / 4.2 |

전 단계 가드 트립 0 · client·server EAGAIN 0 · pending 넘침 0 · client 최고 코어 36~74 %. 손실은 전부 tc 제한 큐 드롭과 함께 증가(회선 상한).

## 경로 사용량 (상향 path0 / path1, Mbit/s, 상한 10)
| Mbps | duplicate | 1.4.3b aggregate | 1.4.1 aggregate |
|---|---|---|---|
| 6 | 9.4 / 9.5 | 5.1 / 4.4 | 5.1 / 4.3 |
| 10 | 10.0 / 10.0 | 8.1 / 7.1 | 8.5 / 6.7 |
| 12 | 10.0 / 10.0 | 9.4 / 8.3 | 9.3 / 8.4 |

- duplicate 는 앱 1 Mbps 당 경로마다 ~1.57 Mbit. 8 Mbps 에서 두 경로가 각 ~9,000 패킷 버렸는데 손실 0.39 % — 두 경로가 서로 다른 패킷을 버려 수신 측이 합친 뒤 FEC 로 복구한 것으로 보임.
- aggregate 12 Mbps 에서 두 경로 합 17.7 / 20 Mbit(88 %). 상향 배분이 path0 쪽 ~53:47 로 기울어 path0 이 먼저 상한에 닿는다 — 이론치(2배)에 못 미치는 원인, 2026-10-23 VM 시험과 같은 현상.
- 재정렬(ooo, 상향): aggregate 10~16 Mbps 1.5만~4.7만 건 vs duplicate ~4천 건(경로 지연차).

## aggregate path0 차단 (1.4.3b, 10 Mbps, 20~40초 client iptables DROP, 3회)
| 구간 | 상향 손실 | 하향 손실 |
|---|---|---|
| 차단 전 2~20 s | 0~0.005 % | 0 % |
| 차단 중 20~40 s | 23.9 / 24.9 / 25.3 % | 15.8~16.4 % |
| 복구 후 40~58 s | 2.3~3.0 % | 0.7~1.7 % |

- 차단 중 손실은 path1 하나(10 Mbit)로 10 Mbps 를 못 싣는 **용량 부족**(path1 tc 드롭 회당 ~8,700) — 이 설계로는 검출 시간을 분리하지 못한다.
- 복구 후 18초 창에도 2~3 % 손실 — 배분 재수렴 지연으로 추정. 초당 자료를 저장하지 않아 지속 시간은 미확인.

## 판단
- 회선이 경로당 10 Mbit 로 막히면 **aggregate 가 duplicate 보다 약 1.5배**(손실 1 % 기준 12 vs 8 Mbps, 무손실 기준 12 vs 6). 10-23 VM 시험(30 vs 20)과 같은 비율.
- 1.4.3b 와 1.4.1 aggregate 는 12 Mbps 까지 같다. 14 Mbps 5.7 vs 2.3 % 는 1회·포화 구간이라 차이 단정 불가.
- aggregate 는 경로 하나가 빠지면 남은 경로 용량을 넘는 몫이 그대로 손실, 복구 직후에도 몇 % 남는다.

## 정리
drop-in·tc·iptables 제거, 기본 바이너리 1.4.3 태그 `aa60be9f`, duplicate, qdisc 기본(client fq_codel · server mq), 유닛 active, WG ping 정상. sv1 운영 PID·md5 불변.
