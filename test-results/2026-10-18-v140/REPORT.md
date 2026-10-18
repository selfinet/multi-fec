# v1.4.0 테스트망 검증 (2026-10-18 19:30 ~ KST)

대상: 1.4.0 (`--config`·기본값·키 입력·회선 지정 — `DESIGN-1.4.0.md`, CLAUDE.md §30). 정적 빌드 md5 `1ed70fd7`
(T1~T5 는 직전 빌드 `ed78e2e3` — 차이는 §T6 의 라우트 기록 수정 1건이며 데이터 경로 무관).
신규 VM 테스트망(c `.92` · r `.88`/`.117` · s `.102`). 서비스망·sv1 운영은 접속·변경하지 않았다. 원자료 `raw/`.

## 요약

| 시험 | 결과 |
|---|---|
| T1 바이너리만 교체(기존 유닛) | 터널 정상, 3대 `ps` 에 `-k ****`, 키 지문 3대 동일. client·server 는 전 옵션 명시라 "기본값 적용" 없음, relay 만 `sock-buf=4096` |
| T2 1.3.1 ↔ 1.4.0 혼용 4조합 | 전부 ping 손실 0%, 두 경로 RUNNING |
| T3 `--config` + 템플릿 유닛 | 4줄 client 설정이 테스트망 운영값과 같은 기본값으로 채워짐. 터널 10/10, `ps` 에는 `--config <경로>` 만 |
| T3 `--check` 포트 충돌 | 기존 유닛이 떠 있는 상태에서 새 인스턴스 점검 → `already bound … SO_REUSEPORT` 오류로 막음 |
| T4 다중 인스턴스 | 두 번째 서버 인스턴스를 멈춰도 다른 인스턴스 FIFO 유지, FIFO 명령 반영, 설정 간 포트 충돌 검출 |
| T5 relay route `via ens19` | 소스 `.117` upstream **ens19 144 · ens18 0** (같은 날 오전 무설정 실측 ens18 346 · ens19 0) |
| T5b client `via` 같은 목적지 2회선 | `dev=ens18`/`dev=ens19` 분리, 두 경로 RUNNING (첫 보고 1회 owd 이상값 — 재현 안 됨) |
| T6 `--apply-routes`/`--remove-routes` | gw 없음 거부 · 설치 · 멱등 · 공유 유지 · 설정 변경 정리 · 남의 라우트 보호 · netplan 동일 라우트 보존. **결함 1건 발견·수정** |
| T7 터널 루프 | path 가 `wg-fec` 로 라우팅 → `--check` 오류 + 기동 거부(rc 1) |
| T8 부하 회귀 (mfgen 10·20 Mbps) | 1.3.6 · 4 MB 와 같은 수준(손실 0~0.023%, 드롭 0~1). FEC 모드 0↔1 혼용 동작(1회 이상치 재현 안 됨) |

## T1. 바이너리만 교체 — `raw/t1_binary_swap.txt`

기존 유닛(`-k ${KEY}` 등 인자 펼침)을 그대로 두고 3대 바이너리만 1.4.0. 일반 계정(`stevekim`)으로 본 `ps`:
```
/usr/sbin/multi-fec-dist -c -l 127.0.0.1:51821 --path 0.0.0.0:192.168.100.88:443 --path 0.0.0.0:192.168.100.117:443 -k ********…
/usr/sbin/multi-fec-dist -r -l 192.168.100.88:443 --upstream 192.168.100.102:443 --upstream-local 192.168.100.88 -k ********…
```
3대 기동 로그 `key kf:53d21bbd from command line`. relay 유닛은 `--sock-buf` 를 주지 않아 `v1.4.0 defaults in effect: sock-buf=4096`
(1.3.6 까지는 OS 기본 — r 은 sysctl `rmem_default` 4 MB). 경로 보고 `… dev=ens18`.

## T2. 혼용 — `raw/t2_mixed.txt`

| c | r | s | ping 10 | 경로 |
|---|---|---|---|---|
| 1.4.0 | 1.3.1 | 1.4.0 | 0% | RUNNING ×2 |
| 1.3.1 | 1.4.0 | 1.3.1 | 0% | RUNNING ×2 |
| 1.4.0 | 1.4.0 | 1.3.1 | 0% | RUNNING ×2 |
| 1.3.1 | 1.3.1 | 1.4.0 | 0% | RUNNING ×2 |

유닛이 `--auth-interval 60` 을 명시하므로 기본값 변경(30→60)의 영향이 없다. 옵션을 생략한 1.3.x 상대와는 어긋난다(루프백 확인: 60 vs 30 → 0/150).

## T3. `--config` + 템플릿 유닛 — `raw/t3_*.txt`

새 형식 설정을 별도 인스턴스 이름(`c140`·`r1-140`·`r2-140`·`s140`)으로 만들고(기존 conf 무변경, 키는 화면에 찍지 않고 옮김) 기존 유닛 정지 → `multi-fec@<인스턴스>` 기동.
client 설정 4줄(`mode`·`path`×2·`key`) — `--check` 의 출처 표에서 나머지 13개가 `default` 이고 값이 테스트망 운영값과 같다.
기동 전 `--check` 가 **실행 중인 기존 유닛과의 포트 충돌**을 오류로 냈다(이전 절차의 함정 — 둘이 뜨면 `SO_REUSEPORT` 로 나눠 받는다).
전환 후 ping 10/10(53.1 ms), 두 경로 RUNNING, `ps`(일반 계정) = `/usr/sbin/multi-fec-dist --config /etc/multi-fec/c140.conf`,
FIFO `/run/multi-fec/c140.fifo`·`s140.fifo` 자동 생성.

## T4. 한 호스트 다중 인스턴스 — `raw/t4_multi_instance.txt`

s 에 `s2-140`(:4443) 기동 → FIFO `s140`·`s2-140` 공존 → `s2-140` 정지 후에도 `s140.fifo` 유지, `echo "fec 5:1,20:4" > s140.fifo` 반영.
`:443` 을 쓰는 세 번째 설정의 `--check` = 오류 2(실행 중 프로세스가 포트 보유 · 같은 디렉터리 설정과 겹침).

## T5. 회선 지정

**relay route-file `via ens19 local .117`** (`raw/t5_relay_via.txt`) — r2 를 `route-file` 로 바꾸고 10초 캡처:

| | ens18 | ens19 |
|---|---|---|
| 오전(무설정, `--upstream-local .117`) | 346 | 0 |
| 1.4.0 route `via ens19` | **0** | **144** (MAC = ens19) |

터널·두 경로 정상 유지.

**client `via` 로 같은 목적지(s:443) 2회선** (`raw/t5b_*`, `t5c_*`, `t5d_*`) — NIC 2개인 r 에 임시 client 인스턴스:
`path = 192.168.100.102:443 via ens18` / `via ens19`. 소스는 인터페이스 IPv4(.88/.117)로 자동 지정(같은 목적지라 mud 경로 키 충돌 방지),
`--check` 와 보고 모두 `dev=ens18`/`dev=ens19`, 두 경로 RUNNING.
- 첫 실행의 첫 보고에서 owd 수십억 ms(이상값) 1회 → 95초 재실행(보고 3회)은 0.43~0.49 ms 정상. **재현 안 됨, 원인 미확인.**
- 경로별 tx/rx 가 엇갈리는 현상(590/295 · 297/590)은 **1.3.6 바이너리로 같은 두 경로를 띄워도 동일**(t5c B) — 1.4.0 과 무관.
- 트래픽은 mud probe 뿐(실 IP 간, 수 pps).

## T6. `--apply-routes` / `--remove-routes` — `raw/t6_apply_routes*.txt`

r 에서 문서용 주소(198.51.100.x)로, 인스턴스는 띄우지 않고(트래픽 없음):

| 단계 | 결과 |
|---|---|
| `via ens19`, gw 없음, ens19 default 없음 | `no gateway known for ens19 … add "gw <ip>"` rc 1 |
| gw 지정 | `installed`, 기록 `rt1.routes` |
| 반복 | `already present` (멱등) |
| 두 번째 인스턴스가 같은 라우트 | `already present`, 양쪽 기록 |
| rt1 제거 | `kept (another instance uses it)` |
| rt2 제거 | `removed` |
| 설정 변경 .7 → .9 | .9 설치 + .7 `removed (no longer configured)` |
| 운영자가 건 다른 `/32` 존재 | `not overwriting` rc 1, 기존 라우트 유지 |
| netplan 식 동일 라우트 | `already present`, 기록 안 함 → `--remove-routes` 후에도 남음 |

**발견·수정한 결함**: 첫 실행에서 두 번째 인스턴스가 공유 라우트를 기록하지 않아 rt1 제거 시 rt2 가 쓰는 라우트가 지워졌다
(`t6_apply_routes.txt` 4·5단계). 다른 인스턴스 기록이 있으면 함께 기록하도록 고쳐 재실행(`t6_apply_routes_v2.txt`) 전 단계 통과.
시험 라우트·기록 파일 0개로 정리.

## T7. 터널 루프 차단 — `raw/t7_loop_guard.txt`

c 에서 `path = 10.9.20.1:443`(WG 안쪽 주소 → `wg-fec`): `--check` `[ERR] … routed into tunnel wg-fec`, 기동 `FATAL … refusing to start` rc 1.

## T8. 부하 회귀 — `v140_load.sh`·`v140_mix.sh`, `raw/load/`

기존 유닛(전 옵션 명시) + 1.4.0, sysctl 기본, relay drop-in 없음(relay 는 1.4.0 기본 `sock-buf 4096`), mfgen 10·20 Mbps 각 3분,
가드 `vm` 선기동(트립 0), ping 20 pps. 비교 대상은 1.3.6 · 4 MB 저녁 3회(`../2026-10-05-vm-guard-calib/raw/bufx_1017/K4096_r*`).

| 회차 | FEC 모드 c / s | 10 Mbps 상/하 % | 20 Mbps 상/하 % | 소켓 드롭 c/r/s | p50 10/20 ms | ping >200 ms 10/20 |
|---|---|---|---|---|---|---|
| V140_a | 1 / 1 | 0 / 0 | 0 / 0.023 | 0 / 0 / 1 | 52.3 / 54.6 | 55 / 77 |
| V140_b | 1 / 1 | 0 / 0 | 0 / 0 | 0 / 0 / 0 | 53.0 / 55.2 | 156 / 7 |
| (1.3.6 4 MB, 3회) | 1 / 1 | 0~0.34 / 0~0.28 | 0~0.008 / 0~0.004 | 0~31 합 | 52.8~52.9 / 53.1~55.5 | 44~83 / 15~54 |
| V140_mix | **0** / 1 | 0 / 0 | **1.08 / 3.60** | 3,301 / 0 / 15,373 | 61.5 / 63.3 | 37 / 155(+손실 131) |
| V140_mix2 (반복) | **0** / 1 | 0 / 0 | **0 / 0** | 0 / 0 / 0 | 61.0 / 60.8 | 21 / 24 |
| V140_m00 | **0 / 0** | 0 / 0 | 0.47 / 0.33 | 2,869 / 0 / 34 | 68.3 / 69.3 | 12 / 16 |

- **1.4.0 은 1.3.6 · 4 MB 와 같은 수준이다**(데이터 손실 0~0.023%, 드롭 0~1). 지연 꼬리 편차(>200 ms 7~156)는 1.3.6 3회의 범위와 같고
  §16-4(그 보고서)의 VM 정지 사건이 좌우한다.
- **FEC 모드 0↔1 혼용은 동작한다** — 손실 있는 경로(netem 5%/2%)에서도 10 Mbps 두 번 다 0, 20 Mbps 반복 0. 첫 혼용 회차의 20 Mbps
  손실(1.08/3.60%, s 드롭 1.5만)은 같은 구간 s 의 전체 CPU 100% 순간(가드 1/3, 평균은 51% 로 오히려 낮음)과 함께였고 **반복에서 재현되지 않았다.**
- mode 0 은 원본을 최대 `--fec-timeout` 만큼 모아 보내므로 그 방향마다 p50 이 약 +8 ms(혼용 61 ms, 양쪽 0 이면 68~69 ms).
  양쪽 0 은 20 Mbps 에서 0.47/0.33% 손실·c 드롭 2,869 — 고레이트에서 mode 1(기본값)보다 불리하다. 1회씩이라 순위는 참고만.

**원상 복구 확인**(20:06, 20:22): 3대 v1.3.1(md5 `ddb8d458`) · `client.conf`/`server.conf` `FEC_MODE=1` 복원 · sysctl 원위치 ·
relay drop-in 0 · 템플릿 유닛·`*-140.conf`·`routes-r2`·`/run/multi-fec/*.routes` 제거 · 터널 ping 10/10 53.7 ms.
`/usr/sbin/multi-fec-dist.v1.4.0` 는 각 호스트에 남겨 두었다(비활성). sv1 운영 `multi-fec-server` 무접촉(PID 754, 시작 08-12 18:53:47,
md5 `3db3617e`). 서비스망은 접속하지 않았다.

## 남은 것

- 서비스망 적용은 별도 결정. 가장 보수적인 경로는 **기존 유닛 유지 + 바이너리만 교체**(T1 — 명시 옵션 그대로).
- 실제 2회선(서로 다른 ISP) 환경 검증은 없다 — 테스트망 r 의 두 NIC 는 같은 L2·같은 게이트웨이다.
- T5b 첫 보고의 owd 이상값 원인 미확인(재현 안 됨).
