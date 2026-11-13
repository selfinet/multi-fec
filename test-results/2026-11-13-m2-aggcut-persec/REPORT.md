# aggregate 경로 차단·복구 — 초 단위 기록 (mini 테스트망, 2026-11-13)

하네스 `cutps.py`(`2026-11-12-m2-agg-ratelimit/aggtest.py` 복사 + 단계 `cutps`, mfgen 수신 시작 시각·tc 0.5초 샘플 기록),
분석 `analyze.py`, 원자료 `raw_<mode>_<rep>.json`·`results.jsonl`·`run.log`·`full.out`, 초 단위 표 `analysis.txt`.
09:48~09:55 UTC, 사용자 승인. 바이너리 1.4.3b(86e6683, sha256 `253ae751…`, `--version` 표기는 1.4.3). 공유 세션 multi-fec-c1 에 사용·반납 알림.

## 목적
2026-11-12 시험(10 Mbps)에서 aggregate path0 차단 중 손실 24~25 % 는 용량 부족이었고, 복구 후 18초 창에도 2~3 % 손실이 남았다.
초 단위 자료가 없어 ① 죽은 경로 검출 시간 ② 복구 후 path0 재사용까지의 시간 ③ 복구 후 손실의 원인을 알 수 없었다.
이번에는 **경로 하나로 감당되는 6 Mbps**(11-12 duplicate 6 Mbps 경로당 9.4 Mbit, 손실 0)로 용량 부족을 없애고 초 단위로 기록했다.

## 조건
- 11-12 와 같음: 두 호스트 enp3s0·enp4s0 HTB `10mbit burst 15k` + pfifo 100, u32 로 각 경로 multi-fec UDP 만 제한. client·server drop-in `--multipath-mode aggregate`(cmdline 확인).
- mfgen 양방향 6 Mbps(625 pkt/s, 1200 B) 90초, 20초 시점 client `iptables -I OUTPUT -o enp3s0 … -d 192.168.2.91 --dport 443 -j DROP`, 19.9초 후 해제.
- aggregate 3회 + 비교 duplicate 1회. 가드 client 85 %·server 88 %·코어 95 %.
- 시각 축: 모두 원격 호스트 시계(client↔server chrony 오프셋 ~µs). 차단 시각은 iptables 명령 **완료 후** `date` 라 실제 차단은 기록보다 조금 이르다(아래 −1초 칸 손실).
- path0 상향은 iptables 가 qdisc 앞에서 버리므로 차단 중 tc 전송량 0 = 송신 시도분은 보이지 않는다.

## 결과 요약
| 회차 | 차단 때 상향 손실 | 하향 손실 | 복구 후 손실 상/하 | path0 재사용(복구 후) 상/하 | 90초 상향 손실 | tc 드롭 |
|---|---|---|---|---|---|---|
| aggregate 1 | 159 패킷 | 2 | 8 / 6 | 1~2초 / 1~2초 | 0.34 % | 0 |
| aggregate 2 | 161 | 1 | 6 / 2 | 1~2초 / 0~1초 | 0.39 % | 0 |
| aggregate 3 | 136 | 2 | 1 / 1 | 1~2초 / 1~2초 | 0.30 % | 0 |
| duplicate | 4 | 4 | 9 / 6 | 0~1초 / 1~2초 | 0 % | 0 |

- 전 회차 가드 트립 0 · client·server EAGAIN 0 · pending 넘침 0 · client 최고 코어 46~64 %.
- "재사용" = path0 전송량이 차단 전 5초 평균의 50 % 이상이 된 첫 1초 칸. 복구 후 손실 수 패킷은 초당 수신 집계의 잡음(±0.1 %) 범위.
- 차단 손실 136~161 패킷 ≈ 전체 0.22~0.26초 분량, path0 몫(~40 %) 기준 약 0.6초 분량 — 검출 전까지 path0 으로 보낸 몫.

## 초 단위 (aggregate 1회차, 0 = 차단 기록 시각, 19.9 = 해제)
| t(s) | 상향 손실 | path0↑ | path1↑ | path0↓ | path1↓ (Mbit/s) |
|---|---|---|---|---|---|
| −2 | 0 % | 2.83 | 6.56 | 5.45 | 3.62 |
| −1 | 5.4 % | 4.09 | 5.43 | 5.30 | 3.78 |
| 0 | 15.2 % | 0.37 | 6.49 | 2.18 | 6.95 |
| 1 | 9.8 % | 0 | 8.61 | 0.19 | 8.93 |
| 2~19 | 0 % | 0 | 9.2~9.5 | 0.17~0.19 | 8.9 |
| 20 (해제 후 0.1~1.1 s) | 0 % | 0.02 | 9.26 | 0.18 | 8.94 |
| 21 (1.1~2.1 s) | 0 % | 3.34 | 6.14 | 3.33 | 5.75 |
| 22 이후 | 0 % | 3.4~4.9 | 4.5~6.0 | 5.2~6.0 | 3.1~3.9 |

다른 회차도 같은 모양(`analysis.txt`). 차단 중 path0↓ 0.18 Mbit 은 probe 분량.

## 판단
- **차단 검출**: 손실이 −1~1초 칸에만 있고 2초 칸부터 path1 이 전량(9.3 Mbit)을 싣는다 → 1~2초 안에 path0 을 뺀다. 설계(§21-가 `MUD_PATH_DEAD_TIMEOUT` 1초·손실률 1초 재계산)와 맞다.
- **하향은 차단 영향이 거의 없다**: 막힌 것은 client 송신뿐이라 server 가 path0 을 뺄 때까지 보낸 하향도 그대로 도착했다.
- **복구 후 재합류**: 해제 후 1~2초 안에 path0 이 차단 전 몫(상향 ~3.8, 하향 ~5.4 Mbit)을 되찾고 손실 없음. 1초 단위 손실률 재계산(`mud_update_rl`, branch 1)이 LOSSY→RUNNING 전환을 정하는 것으로 보인다.
- **11-12 의 복구 후 2~3 % 설명**: 이 1~2초 재합류 지연 동안 10 Mbps 가 path1 하나의 용량(10 Mbit, 실효 ~9.4)을 넘은 몫. 25 % × ~1.5초 ÷ 18초 ≈ 2 % 로 크기도 맞다. aggregate 복구 자체의 결함은 아니다.
- **duplicate 는 차단·복구 모두 손실 0** — 끊김 순간 무손실이 필요하면 duplicate, 처리량이 필요하면 aggregate(경로 하나 장애 시 남은 용량을 넘는 몫은 손실).

## 한계
- 1회 조건(6 Mbps·client 송신 차단)만. server 쪽 차단·링크 down·relay 정지·높은 부하에서의 재합류는 미측정.
- 경로 상태(LOSSY/RUNNING) 전환 시각은 로그가 30초 주기라 직접 보지 못했고 tc 전송량으로 추정했다.
- 1.4.1 은 이번에 돌리지 않았다(11-12 에서 aggregate 12 Mbps 까지 1.4.3b 와 같음).

## 정리
drop-in·tc·iptables·tc 샘플러·mfgen·가드 종료, 기본 바이너리 1.4.3 태그 `aa60be9f`·duplicate, qdisc client fq_codel · server mq, 유닛 active, WG ping 정상.
sv1 운영 multi-fec-server PID 754·md5 `3db3617e` 불변. c1 에 반납 알림.
