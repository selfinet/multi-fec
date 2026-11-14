# relay route `ports` — mini 실장비 시험 (2026-11-15)

대상 빌드: `v1.4.3-14-g0d28263` (`multi-fec-dist` sha256 `7a0df002…`, 정적·strip). 1차 빌드 `2b6a311`(`a2417db6…`)은 M3 에서 결함이 나와 교체.
장비: mini 테스트망 — m_server `test-server` .2.91(server + relay `172.30.4.1:8443` → 로컬 server `172.30.4.1:443`), m_client `client-test` .2.90
(path[0] `192.168.2.91:443 via enp3s0` 직결, path[1] `172.30.4.1:8443 via enp4s0` relay 경유, duplicate). 부하 없음(WG ping·저속 UDP 측정만).

relay 에만 drop-in 으로 시험 바이너리(`/usr/sbin/multi-fec-dist.v1.4.3p`), `relay.routes` 에 `ports 21017,21004`(백업 후). 같은 호스트 경로라
**ECMP 효과는 볼 수 없다** — 기능·호환 시험이다.

## 결과

| # | 시험 | 결과 |
|---|---|---|
| M1 | 새 바이너리 + 기존 설정(ports 없음) | relay 정상, upstream 출발 포트 커널 배정(49584), 두 경로 RUNNING, WG ping 0% |
| M2 | `ports 21017,21004` 추가 → `--check` → relay 재시작 (client ping 0.2 s 간격 중) | `--check` "ports 21017,21004 usable" 오류 0 · 출발 포트 **21017** · 재시작 중 ping **75/75 손실 0%**(duplicate 가 메움) |
| M3 (1차 빌드) | client 4초 간격 5회 + 1초 간격 3회 재시작 | **결함: 회수 0, 커널 포트 대체 7** — 아래 |
| M4 | relay 재시작 직후 | 즉시 **21017** |
| M3 (수정 빌드) | client 4초 간격 5회 | 회수 4·대체 0 — **5회 모두 지정 포트**(client 무수신 ~4.3 s 세션의 포트 회수) |
| M3b (수정 빌드) | client 1초 간격 3회 | 회수 1·대체 2(커널 포트) — 직전 세션이 3 s 기준 전이라 설계대로. 마지막 세션이 커널 포트로 남을 수 있다(다음 새 세션까지) |
| M5 | server 를 **1.4.1** 로(drop-in) → relay 고정 포트로 접속 | path[1] RUNNING, ping 0% — 와이어 호환 |
| M6 | `tools/mf-portprobe.py` 실장비 | relay 호스트→server 1.4.1·1.4.3, client→relay 1.4.3p 모두 응답·손실 0(갈래 1개, 직결이라 정상). 간격 0.1 s 는 1.4.3 속도 제한으로 17~67% 손실(예상대로) |

## M3 결함과 수정

relay 세션의 `last_active` 는 **양방향** 패킷으로 갱신된다. client 가 재시작돼 사라져도 server 는 그 옛 경로로 probe 를 계속 보낸다
(mud 가 PASSIVE 경로를 지우는 5분 동안). 그래서 옛 세션이 "3초 무수신" 에 걸리지 않아 회수가 한 번도 안 됐다.
루프백 시험의 가짜 upstream 은 client 가 보낼 때만 답해 이 조건을 재현하지 못했다.

수정(`0d28263`): 세션에 `last_up`(client → relay 수신 시각)을 두고 회수 판단에 쓴다. 시험 sink 도 server 처럼 스스로 0.1 s 마다 probe 를 보내게 해
**A/B 확인 — 수정 전 코드 27/29(회수 실패), 수정 후 29/29**.

참고: 60초 세션 만료도 같은 `last_active` 를 쓰므로, 사라진 client 의 relay 세션은 server probe 가 이어지는 동안(최대 ~5분) 남는다. ports 기능 이전부터의
동작이고 이번에 바꾸지 않았다(포트 풀은 위 회수로 해결).

## 원복 (2026-11-15 18:17 UTC)

drop-in 2개 삭제, `relay.routes` 원본(백업과 cmp 일치 후 백업 삭제), daemon-reload·재시작 → server·relay·client 모두 1.4.3 `aa60be9f`, drop-in conf 0,
iptables DROP 0, mfgen 0, wg-test noqueue, WG ping 0%. 남긴 것: m_server `/usr/sbin/multi-fec-dist.v1.4.3p`(미사용 사본). sv1 운영 PID 754 · md5 `3db3617e` 불변.
