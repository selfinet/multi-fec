# multi-fec 1.4.0 설계 — 고객 배포용 단순 설정

- 상태: **구현 완료 (v1.4.0, 2026-10-18)** · 테스트망 검증 `test-results/2026-10-18-v140/REPORT.md` · 설계와 달라진 점은 §13
- 범위: client · server · relay 의 설정·기동·키 입력·회선 지정.
- 와이어 포맷: **변경 없음.** 1.3.x 와 혼용 가능해야 한다(§10).

## 0. 1.3.6 대비 변경 요약

| 구분 | 1.3.6 | 1.4.0 |
|---|---|---|
| 설정 | conf 를 systemd 가 인자로 펼침 | multi-fec 이 `--config` 파일을 직접 읽음 |
| 고객 설정 분량 | conf 14줄 + 긴 `ExecStart` | 4~5줄 |
| systemd 유닛 | 역할·인스턴스마다 다른 유닛 | 템플릿 `multi-fec@.service` 하나 |
| `ps` 노출 | 키 포함 전 옵션 | `--config <경로>` 만 |
| 키 입력 | `-k`, `--route` | + `key =`, `--key-file`, `MF_KEY`, `--route-file`. `-k` 는 `ps` 에서 가림 |
| path | `소스:목적지:포트` | + `목적지:포트`(소스 자동) · `via <if>` · `gw <IP>` |
| relay 라우트 | 유닛에 `--route` 반복 | `routes` 파일, 줄마다 `via`/`gw`/`local` 선택 |
| 다회선 | 정책 라우팅 수동, 틀려도 무경고 | `--apply-routes`(/32) · `via` · `--check` 경고 |
| 기본값 | 코드 기본 ≠ 실사용 | 실사용값이 기본(§4) |

바뀌지 않는 것: 와이어 포맷, FEC·mud·obfs·dedup·세션 코드, 기존 명령행 방식, FIFO 런타임 변경.

## 1. 목적

c·s 를 고객에게 한 벌로 제공할 때 **설정 파일 하나에 필수 4~5줄**로 끝나게 하고, 운영 중인 서비스망은 기존 값을 그대로 옮길 수 있게 한다.

현재 구조의 문제(코드 기준):

| 문제 | 원인 |
|---|---|
| 유닛 `ExecStart` 가 길고 고객이 고쳐야 한다 | 설정 파일을 읽는 기능이 없어 systemd 가 conf 값을 인자로 펼친다 |
| 운영값 11개를 매번 명시해야 한다 | 코드 기본값(`main.cpp:44,62~69`)과 실사용값이 다르다 |
| 키가 `ps` / `/proc/<pid>/cmdline` 에 보인다 | 키를 인자(`-k`, `--route`)로만 받는다 |
| relay 에 지사를 더하려면 유닛을 고쳐야 한다 | 키별 라우트가 `--route` 인자다 |
| 다회선에서 조용히 한 회선만 쓴다 | 소스 IP 는 회선을 정하지 않는다(§6-1) — 확인 수단도 없다 |

## 2. 비목표

- 와이어 포맷·프로토콜 변경
- multi-fec 데몬이 **실행 중** 호스트 라우팅 테이블을 관리하는 것(§7 — 기동 전 보조 명령으로 분리)

## 3. 설정 파일 — `--config FILE`

```ini
# /etc/multi-fec/client.conf  (600 root)
mode = client
path = 203.0.113.10:443
path = 198.51.100.20:443
key  = <PSK>
```

규칙:

- **항목 이름 = CLI 긴 옵션 이름에서 `--` 를 뺀 것.** (`fec-timeout = 20` ↔ `--fec-timeout 20`). 짧은 옵션은 긴 이름으로 쓴다(`-f` → `fec`, `-k` → `key`, `-l` → `listen`).
- 예외 하나: 설정 파일의 `mode` 는 동작 모드(`client|server|relay` = `-c/-s/-r`)다. CLI `--mode`(FEC 모드)와 이름이 겹치므로
  **FEC 모드는 `fec-mode`** 로 쓰고, CLI 에도 `--fec-mode` 별칭을 추가한다. `mode = 0|1|2` 처럼 숫자가 오면 *"FEC 모드는 `fec-mode` 로"* 안내와 함께 거부한다.
- **우선순위: 명령행 > 설정 파일 > 내장 기본값.**
- **기본값과 같은 값을 적어도 된다 — 운영 환경에서는 권장한다.** 이후 기본값이 바뀌어도 동작이 고정되고, `--check` 에 출처가 `config` 로 표시된다. 고객 키트는 최소 줄 + `auth-interval` 만 명시한다.
- 반복 옵션(`path`, `accept-local`)은 줄을 반복한다. relay 키 라우트는 `route-file`(§5-1).
- `#` 이후 주석, 빈 줄 무시. 값 앞뒤 공백 제거.
- **모르는 항목·오타·범위 밖 값은 기동 거부**(조용히 기본값으로 돌지 않게 — `--accept-local` 설계 원칙과 같다).
- 파일 권한이 group/other 읽기 가능이면 경고(키가 들어 있으므로).

### 3-1. 바꾼 값 반영

| 항목 | 반영 |
|---|---|
| 모든 항목 | 재시작 |
| `fec`, `mtu`, `fec-mode`, `fec-timeout`, `queue-len` | 기존 FIFO 로 무중단 변경 가능(재시작 시 파일 값으로 복귀) |

## 4. 내장 기본값 변경

c·s 를 같은 버전으로 함께 제공하므로 실사용값(테스트망·서비스망 유닛)을 기본값으로 올린다.

| 항목 | 현재 기본 | 1.4.0 기본 | 상대와 같아야 하나 | 비고 |
|---|---|---|---|---|
| `fec` | 20:10 | **5:1,20:4** | 아니오 — 수신측이 헤더에서 그룹 파라미터를 읽는다 | 저레이트 오버헤드 554%→33% (FEC 튜닝 실측) |
| `fec-mode` | 0 | **1** | 아니오 — 수신측이 패킷마다 type 바이트로 판별(`misc.cpp:190`, `fec_manager.cpp:488`). **2(RNLC)는 양쪽 같아야 한다** | 혼용은 실측 검증 필요(§11) |
| `fec-timeout` | 8 | **10** | 아니오 | |
| `queue-len` | 200 | **500** | 아니오 | |
| `sock-buf` | OS 기본 | **4096** | 아니오 | 아래 근거 |
| `mtu` | 1250 | **1350** | 아니오 | WG MTU 1300 전제 — 키트가 WG 설정을 함께 준다 |
| `multipath-mode` | failover | **duplicate** | 아니오(각자 동작) | 회선 사용량이 경로 수만큼 — 안내서에 명시 |
| `auth-interval` | 30 | **60** | **예** — HMAC 슬롯 `time/auth_interval`(`obfs.cpp:75`) | 아래 주의 |
| `report` | 0 | **60** | 아니오(로그만) | 서비스망·테스트망 모두 60 |
| `fifo` (c·s) | 없음 | **`/run/multi-fec/<인스턴스>.fifo`** | — | 인스턴스 = 설정 파일 이름(확장자 제외). 한 호스트 다중 인스턴스 대비 |
| `wg` (client 리슨 / server upstream) | 필수 | **127.0.0.1:51821 / 127.0.0.1:51820** | — | 다중 인스턴스면 반드시 명시(§9-2) |
| `decode-buf` · `log-level` · `obfs-mode` | 2000 · 4 · quic | 그대로 | | |

**`sock-buf 4096` 근거** (2026-10-17~18 테스트망, 1.3.6):
- UDP 지속: 20 Mbps 데이터 손실 1 MB 0.81/0.52% vs 4 MB 0.003/0.001%, 소켓 드롭 35,334 vs 31(각 3회).
- TCP(iperf3, `--fq-rate`): 20 Mbps 재전송 1 MB 1,188/988 vs 4 MB 27/28, 지연 꼬리는 비슷(>1 s ping 8 vs 14).
- 대가: UDP 실시간 트래픽은 VM 정지 시 손실 대신 지연(p99 수백 ms)으로 나타난다. 실시간 위주 고객은 `sock-buf = 1024`.

**`auth-interval` 주의**: 기본값을 바꾸면 **옵션을 생략한 1.3.x 상대와 어긋나 전 패킷이 조용히 폐기된다.**
c·s 를 함께 올리는 고객 키트에서는 문제없지만,
- 이후 버전에서 이 기본값은 **다시 바꾸지 않는다**(같아야 하는 값의 기본은 고정).
- 우리 relay 를 거치면 relay 의 `auth-interval` 도 60 이어야 한다(서비스망 relay 는 이미 명시).
- 기동 로그에 `auth_interval` 과 키 지문(`kf:`)을 남겨(기존 `main.cpp:1011`) 양쪽 대조로 진단한다.

기동 로그에 **기본값에서 온 항목 목록**을 한 줄로 남긴다(업그레이드로 동작이 바뀐 것을 드러내기 위해).

서비스망 server 유닛(옵션 전부 명시)을 그대로 두고 바이너리만 1.4.0 으로 바꾸면 **동작이 같다** — 바뀌는 기본값을 전부 명시하고 있기 때문이다.

## 5. 키 입력

우선순위: `-k` / `key =` > `--key-file` > 환경변수 `MF_KEY`.

| 방법 | 노출 |
|---|---|
| `key =` (설정 파일, 600 root) | `ps` 에는 `--config <경로>` 만 보인다 |
| `--key-file PATH` | 파일 첫 줄. 여러 인스턴스가 같은 키를 쓸 때 |
| `MF_KEY` (systemd `EnvironmentFile`) | `/proc/<pid>/environ` 은 커널이 소유자·root 만 읽게 한다 |
| `-k KEY` (기존) | 하위 호환 유지. **파싱 직후 argv 의 키를 덮어써** `ps` 에 `-k ********` 로 보이게 한다(기동 직후 짧은 순간·길이는 노출 — 보조 수단) |

공통: 키 값 검증(빈 값·길이·파일 권한) 실패 시 기동 거부. 로그에는 지문(`kf:`)만.

### 5-1. relay `route-file`

```
# /etc/multi-fec/routes   (600 root)
# <키> <upstream ip:port>   [via <NIC>] [gw <IP>] [local <IP>]
<PSK-A>  198.51.100.50:443                        # 다음 홉 = 2단 relay
<PSK-B>  203.0.113.5:50408                        # 다음 홉 = 서버 인스턴스
<PSK-C>  203.0.113.5:50409   via eth1 gw 10.0.0.1 # 이 키만 회선 B
<PSK-D>  203.0.113.6:50402   local 192.0.2.117    # 이 키만 소스 IP 고정
```

- 키별 다음 홉은 지금 `--route` 와 같다(첫 패킷 HMAC 으로 키 결정, 첫 매칭). 지사 추가 = 한 줄 추가 + 재시작. 기존 `--route` 도 유지.
- **키별 회선 지정은 신규.** 현재 라우트 항목은 `키·upstream·HMAC` 뿐이고(`mf_common.h:43~47`) `--upstream-local` 은 전역 하나라(`mf_relay.cpp:288`) 키별 회선을 표현할 수 없다.
  relay 는 **세션마다 upstream 소켓을 따로 만들므로**(`new_upstream_fd()`) 그 소켓에 키별 `bind(local)` / `SO_BINDTODEVICE(via)` 를 걸면 된다 — 소켓 하나인 mud(client)보다 쉽다.
- `--upstream-local` 은 "줄에 지정이 없을 때의 기본값" 으로 남긴다.
- 목적지가 키마다 다르면 `gw` 와 함께 `--apply-routes` 의 /32 로 회선을 나눌 수 있고, **같은 upstream 을 키마다 다른 회선**으로 보내려면 `via`(소켓에 인터페이스 지정)가 필요하다.
- 같은 키가 두 줄에 있으면 `--check` 경고(첫 줄만 쓰인다).

## 6. `path` 형식 (client)

이름은 `path` 를 유지한다(`server` 같은 별칭을 두지 않는다 — 목적지는 대개 relay 이고, 이름이 둘이면 문서가 갈라진다).

```ini
path = 203.0.113.10:443                          # 새 형식 — 소스 자동 (= 0.0.0.0:203.0.113.10:443)
path = 0.0.0.0:203.0.113.10:443                  # 기존 형식(소스:목적지:포트) 그대로 허용
path = 198.51.100.20:443 via eth1                # 회선(인터페이스) 지정
path = 198.51.100.20:443 via eth1 gw 10.0.0.1    # + 게이트웨이 (§7 --apply-routes 용)
```

| 콜론 수 | 해석 |
|---|---|
| 1 | 새 형식(소스 자동) |
| 2 | 기존 형식(`main.cpp:300` 과 동일) |
| 그 외 / 모르는 꼬리 단어 | 기동 거부 |

### 6-1. 소스 IP 는 회선을 정하지 않는다 (근거)

mud 는 송신 시 `ipi_spec_dst`(소스)만 채우고 `ipi_ifindex` 는 0 이다(`mud_lite.c:491~508`).
리눅스 기본 `ip rule` 은 `from all lookup main` 뿐이라 **목적지로만** 경로를 고른다.
단말 → WG → multi-fec 구성에서도 같다 — 회선으로 나가는 바깥 패킷은 multi-fec 이 만들고, 단말 IP 는 WG 안에 암호화되어 있다.

2026-10-18 테스트망 r(ens18 `.88` / ens19 `.117`) 실측:

| 조건 | ens18 | ens19 |
|---|---|---|
| relay-b(`--upstream-local .117`) 실트래픽 10초 | 346 | **0** |
| 임시 `ip rule from .117 → table 102(ens19)` | 0 | **551** |
| 되돌린 뒤 | 286 | 0 |

라우트 없이 소스 자동이면 **두 경로가 모두 RUNNING 인 채 한 회선에 실린다** — 이중화 0, 그 회선 사용량 2배, 로그로는 구분 불가.
소스를 다른 회선 IP 로 명시하면 그 경로가 RUNNING 이 안 된다(구 c LTE, tcpdump 확인). 둘 다 오류 메시지가 없다.

### 6-2. `via <if>` 구현 — `ipi_ifindex` 지정

같은 실측에서 `sendmsg`+`IP_PKTINFO` 에 `ipi_ifindex` 만 채운 시험 프로그램으로 확인했다(정책 라우팅 없음):

| 소스 | ifindex | 나간 NIC |
|---|---|---|
| .117 | 0 (현재 mud) | ens18 |
| .117 | ens19 | **ens19** |
| 0.0.0.0 | ens19 | **ens19, 소스 .117 자동** |
| .117 | ens18 | ens18 (잘못된 조합도 막지 않는다) |

설계:
- `via` 는 **인터페이스만** 받고 소스는 자동으로 둔다(잘못된 조합 방지). DHCP 로 회선 IP 가 바뀌어도 설정을 고칠 필요가 없다.
- 단 **같은 목적지로 여러 회선**이면 mud 경로 키 `(소스, 목적지, 포트)` 가 겹치므로, 기동 시 인터페이스의 IPv4 를 찾아 path 소스로 넣는다.
- 인터넷 목적지는 그 인터페이스로 가는 **라우트가 있어야** 한다. 없으면 커널이 목적지를 온링크로 보고 게이트웨이 없이 보낸다(실측 `ip route get … oif ens19` → `dev ens19`, via 없음 = 도달 불가). → §7.

## 7. 회선 라우팅 — `--apply-routes` / `--remove-routes`

multi-fec 데몬은 라우팅 테이블을 건드리지 않는다. 같은 설정 파일을 읽는 **보조 명령**이 기동 전에 라우트를 건다.

```ini
ExecStartPre=/usr/sbin/multi-fec-dist --config /etc/multi-fec/%i.conf --apply-routes
```

- `via`(+`gw`) 가 있는 path(client)·route 줄(relay)마다 `ip route replace <목적지>/32 via <gw> dev <if>` 와 같은 일을 netlink 로 한다(멱등). 없으면 아무것도 하지 않는다.
- `gw` 생략 시 그 인터페이스의 default 게이트웨이를 쓴다. **못 찾으면 기동 거부.**
- **`add` 가 아니라 `replace`(netlink `NLM_F_CREATE|NLM_F_REPLACE`)** 를 쓴다. `add` 는 이미 있으면 실패한다 —
  2026-10-18 r 실측: 같은 /32 두 번째 `ip route add` → `RTNETLINK answers: File exists`(rc=2), `replace` 는 반복해도 rc=0.
  재시작·다중 인스턴스에서 같은 라우트를 다시 거는 것이 정상 경로이므로 멱등이어야 한다.
- 단 `replace` 는 **남이 건 라우트도 말없이 덮어쓴다**(같은 실측: ens19 로 건 /32 가 `replace … dev ens18` 로 바뀜). 그래서 쓰기 전에 조회한다:

  | 같은 /32 가 이미 있을 때 | 동작 |
  |---|---|
  | 내용(gw·dev)이 같다 | 그대로 둔다 |
  | 이 인스턴스·다른 multi-fec 인스턴스가 건 것(§7-1 기록 파일에 있음) | `replace` |
  | 그 외(netplan·운영자가 건 것)인데 내용이 다르다 | **덮어쓰지 않고 기동 거부** — OS 설정과 충돌을 알린다 |
- /32 라우트 실측(2026-10-18 r, 문서용 주소 `198.51.100.7`):
  - oif 미지정·소스 자동 → 지정 NIC 로 나가고 소스도 그 NIC 주소 → **목적지가 다른 표준 구성(relay 2개)은 `via` 송신 없이 /32 만으로 회선 분리**
  - oif 를 다른 NIC 로 지정 → /32 를 건너뛰고 그 NIC 의 default 로 → 같은 목적지 다회선도 /32 1개 + `via` 로 처리
  - ⚠️ 소스를 **다른 회선 IP 로 명시**하면 /32 를 따라 어긋난 NIC 로 나간다 → 소스는 자동으로 둔다
- /32 는 full tunnel(`AllowedIPs 0.0.0.0/0`) 의 루프 방지도 겸한다(`suppress_prefixlength 0` 아래에서 main 의 /32 가 이긴다).

### 7-1. 라우트를 언제 지우나

**정지·재시작 시에는 지우지 않는다**(`ExecStopPost` 를 두지 않는다):
1. 여러 인스턴스가 같은 /32 를 함께 쓸 수 있다(client-a·client-b 가 같은 relay 로 `via eth1`). 한쪽이 멈추며 지우면 **살아 있는 다른 인스턴스의 경로가 조용히 기본 회선으로 바뀐다.**
2. `Restart=on-failure` 재기동마다 "삭제 → 재추가" 사이에 패킷이 기본 회선으로 샌다.
3. 남겨 둬도 그 목적지로 가는 트래픽(= multi-fec 뿐)에만 영향이 있다.

**설정 변경으로 낡은 라우트 정리**:
- `--apply-routes` 는 자기가 건 라우트를 `/run/multi-fec/<인스턴스>.routes` 에 기록한다(위 "덮어써도 되는가" 판정에도 쓴다).
- 다음 기동 때 "전에 걸었는데 이제 설정에 없는 라우트" 중 **다른 인스턴스의 기록 파일(`/run/multi-fec/*.routes`)에 없는 것만** 지운다.
- 인스턴스 제거(지사 철수 등) 시에는 사람이 `--remove-routes` 를 명시 실행한다(같은 규칙: 다른 설정이 쓰면 남긴다).

데몬이 직접 관리하지 않는 이유: 테스트망 호스트의 `systemd-networkd` 는 `ManageForeignRoutes` 기본값 yes 라 외부에서 건 라우트를 지울 수 있고(시점 미검증), 데몬이 유지하려면 netlink 감시가 필요하다. 라우팅은 OS 설정 계층에 두는 쪽이 추적이 쉽다(2026-08-11 netplan 회귀 사고 참고).
고객 수가 적은 동안은 키트가 netplan `routes:` 조각을 생성해 영구화하는 방식(§9)으로도 충분하다 — 그 경우 multi-fec 은 `--check` 로 검사만 한다.

## 8. `--check`

```bash
multi-fec-dist --config /etc/multi-fec/client.conf --check
```
- 최종 적용값과 출처(`default` / `config` / `cli`) 표. 키는 `kf:` 지문만.
- 파일 권한, 키 검증, relay `routes` 중복 키.
- path·route 별: 소스 IP 가 호스트에 있는지(없어도 기동되던 무음 실패), `via` 인터페이스 존재, 그 인터페이스로 가는 라우트 존재.
- **path 별 `ip route get` 결과 NIC 비교** — 모두 같으면 경고 *"두 경로가 같은 회선(eth0)으로 나감 — 이중화 안 됨"*.
- 목적지가 `wg*`/`tun*` 으로 라우팅되면 오류(터널 루프, CLAUDE.md 규칙 2).
- **다른 인스턴스와의 충돌** — `/etc/multi-fec/*.conf` 를 함께 읽어 `listen`·`wg` 포트가 겹치면 오류.
  mud 소켓(`mud_lite.c:1040`)과 relay 리슨(`common.cpp:853`)이 `SO_REUSEPORT` 라 **같은 포트에 두 번째 프로세스가 오류 없이 떠서 트래픽을 나눠 가진다**(relay 고아 프로세스로 실제 겪음).
- 실행 중 보고(`--report`)에도 path 별 송신 NIC 를 함께 출력한다.

## 9. 배포 — systemd · 키트

### 9-1. 템플릿 유닛 (역할·인스턴스 공통, 하나만 설치)

```ini
# /etc/systemd/system/multi-fec@.service
[Unit]
Description=multi-fec %i
After=network-online.target time-sync.target
Wants=network-online.target time-sync.target

[Service]
Type=simple
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStartPre=/usr/sbin/multi-fec-dist --config /etc/multi-fec/%i.conf --apply-routes
ExecStart=/usr/sbin/multi-fec-dist --config /etc/multi-fec/%i.conf
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

| 줄 | 이유 |
|---|---|
| `%i` | `multi-fec@server-dj08` → `/etc/multi-fec/server-dj08.conf` |
| `time-sync.target` | 시계가 30초 넘게 틀어지면 mud 가 조용히 폐기한다(구 c, chrony 누락으로 +74초 · 터널 무음 정지). 안내서에 시간 동기 필수 |
| `mkdir -p /run/multi-fec` | `RuntimeDirectory=` 를 쓰지 않는다 — systemd 는 유닛 정지 시 그 디렉터리를 지우므로, 여러 인스턴스가 공유하면 한 인스턴스 정지로 **다른 인스턴스의 FIFO 가 사라질 수 있다**(공유 시 동작 미검증). 현 서비스 유닛과 같은 방식 |
| `ExecStopPost` 없음 | §7-1 |
| `network-online.target` | 고정 IP 리슨은 IP 가 올라온 뒤여야 한다(없으면 bind errno 99, exit 1) |

인스턴스별 추가 설정은 drop-in 으로: `systemctl edit multi-fec@relay` → `[Service] LimitNOFILE=4096`
(relay 는 세션당 소켓 1개, 상한 `RELAY_SESSION_MAX` 800 — 기본 한도 1024 안이라 보통 불필요).

### 9-2. 한 호스트 다중 인스턴스

```bash
systemctl enable --now multi-fec@server-dj08 multi-fec@server-dj18   # 지사별 서버
systemctl enable --now multi-fec@client-a multi-fec@client-b         # 지사별 client
systemctl status 'multi-fec@*'
```

| 역할 | 인스턴스마다 달라야 하는 값 |
|---|---|
| client | `wg` 포트(각 WG Endpoint 와 일치), `key` |
| server | `listen`, `wg` 포트(각 WG ListenPort 와 일치), `key` |
| relay | `listen` |

FIFO 는 인스턴스 이름으로 자동 분리된다(§4). 같은 relay 를 여러 client 인스턴스가 함께 써도 된다(relay 는 (IP, 포트)로 세션을 나눈다).

### 9-3. 기존 유닛에서 옮기기

다른 인스턴스는 별개 프로세스(포트·WG·FIFO 분리)라 **한 번에 하나씩 옮기면 그 인스턴스만 재시작만큼 끊긴다**(단절 길이는 미측정). relay 재시작은 그 relay 를 지나는 전 지사 세션에 영향이 있으나, duplicate 다른 경로가 살아 있으면 공백 없이 넘어간다(2026-09-09 SPOF 시험: 프로세스 1개 장애 공백 0).

1. 1.4.0 바이너리 설치 → `<인스턴스>.conf` 작성(운영은 전 옵션 명시) → `--check`
2. **기존 유닛을 먼저 정지·비활성화**한 뒤 새 인스턴스 기동
   ```bash
   systemctl disable --now <기존 유닛>
   systemctl enable --now multi-fec@<인스턴스>
   ```
3. 확인: `ss -lunp | grep ':<포트> '` 프로세스 1개 · `systemctl is-enabled <기존 유닛>` = disabled(재부팅 시 동시 기동 방지) · 경로 RUNNING · 터널
4. 되돌리기는 반대 순서. 기존 유닛 파일은 남겨 둔다.
5. 유닛 이름이 바뀌므로 모니터링(exporter `-u`)·점검 스크립트·`journalctl -u` 참조를 함께 고친다.

**가장 보수적인 경로**: 기존 유닛은 그대로 두고 바이너리만 1.4.0 으로 교체(명시 옵션이 그대로 적용, `-k` 만 `ps` 에서 가려짐). 템플릿 전환은 별도 시점에.

### 9-4. 고객 키트 — `mf-pair`

기존 `mf-newkey.sh` 확장. 우리 쪽에서 1회 실행:
```bash
mf-pair --name customerA --server 203.0.113.10:443 \
        --path 198.51.100.20:443 --path 198.51.100.30:443 [--via eth0,eth1]
```
출력: `client/` · `server/` 각각 `multi-fec.conf` + `wg-fec.conf`(키쌍·터널 IP·MTU 1300·필요 시 /32 PostUp) +
우리 relay `routes` 에 넣을 한 줄 + 키 지문 + 설치 체크리스트(경로별 `ip route get` · 회선별 tcpdump · TX 바이트 확인 포함).

고객 작업:
```bash
cp multi-fec.conf /etc/multi-fec/client.conf; cp wg-fec.conf /etc/wireguard/
systemctl enable --now multi-fec@client wg-quick@wg-fec
multi-fec-dist --config /etc/multi-fec/client.conf --check
```

## 10. 호환성

| 상대 | 결과 |
|---|---|
| 1.4.0 c ↔ 1.4.0 s | 정상(같은 기본값) |
| 1.4.0 c·s ↔ 우리 1.3.x relay | 정상 — relay 는 FEC/mode 를 보지 않고 HMAC 만 검증. relay `--auth-interval 60` 필요 |
| 1.4.0 ↔ 1.3.x 상대(옵션 생략) | **`auth-interval` 만 어긋난다** → 상대에 `--auth-interval 60` 명시 또는 1.4.0 쪽에 `auth-interval = 30` |
| 기존 명령행 방식 | 그대로 동작. 단 생략한 옵션은 새 기본값을 쓴다(기동 로그에 표시) |

## 11. 검증 계획 (테스트망)

1. 단위: 설정 파서(정상·오타·범위·반복·우선순위·`mode` 숫자 안내), path 형식, route-file 형식, 키 입력 경로, argv 덮어쓰기(`/proc/<pid>/cmdline`).
2. CLI 회귀: `test_all_options.py` 등 기존 스위트 + 새 옵션 케이스.
3. 혼용: 1.4.0 c·s ↔ 1.3.1 relay(1단·2단) · **`fec-mode` 0↔1 혼용**(코드상 가능, 미실측) · 1.4.0 ↔ 1.3.1 c/s 에 `auth-interval` 맞춘 경우.
4. `ps` 노출: 일반 사용자 계정으로 `ps`·`/proc/<pid>/cmdline`·`environ` 확인.
5. 회선: c 에 NIC 를 추가해 실제 2회선 — `--apply-routes` 로 /32, `via` 로 같은 목적지 2회선, relay route 줄 `via`/`local`, `--check` 경고, 낡은 라우트 정리(§7-1), 라우트 삭제 시 보고 로그.
6. 다중 인스턴스: 템플릿 인스턴스 2개 + 기존 유닛 혼재, 한 인스턴스 정지 시 다른 인스턴스 FIFO·라우트 유지, 포트 중복 `--check` 오류.
7. 지속 부하: 기존 하네스(`tp_ladder.sh`, `run_load.sh` / `run_tcp.sh`)로 1.3.6 대비 손실·지연 회귀 없음.

## 12. 미결정

| 항목 | 선택지 |
|---|---|
| `sock-buf` 기본 | 4096(TCP·고레이트 유리) vs 1024(실시간 UDP 지연 유리) — 현 설계 4096 |
| `multipath-mode` 기본 | duplicate(제품 사양) vs failover(회선 사용량 보수적) |
| 설정 재적재 | `systemctl reload`(SIGHUP) — FIFO 가능 항목, relay `routes` 무중단 반영 여부 |
| 비 root 실행 | `CAP_NET_ADMIN`(sock-buf FORCE·라우트)·`CAP_NET_BIND_SERVICE`(443)·`CAP_NET_RAW`(`SO_BINDTODEVICE`) 부여 방식 |
| DHCP 회선 | 운영 중 인터페이스 IP·게이트웨이 변경 추적 여부(현 설계는 기동 시 1회) |
| 라우트 영구화 | `--apply-routes`(§7) vs `mf-pair` 의 netplan 생성 + `--check` 만 |

## 부록 A. 역할별 설정 예

IP 는 문서용 주소, 키는 `<PSK>`. 모든 파일 `600 root`.

**client — 기본(relay 2개, 회선 1개)** `multi-fec@client`
```ini
mode = client
path = 198.51.100.10:443
path = 198.51.100.20:443
key  = <PSK>
```

**client — 회선 2개** 
```ini
mode = client
path = 198.51.100.10:443 via eth0
path = 198.51.100.20:443 via eth1 gw 10.0.0.1
key  = <PSK>
```

**client — 운영용 전부 명시**
```ini
mode           = client
wg             = 127.0.0.1:51821
path           = 198.51.100.10:443
path           = 198.51.100.20:443
key            = <PSK>
obfs-mode      = quic
auth-interval  = 60
multipath-mode = duplicate
fec            = 5:1,20:4
fec-mode       = 1
fec-timeout    = 10
mtu            = 1350
decode-buf     = 2000
queue-len      = 500
sock-buf       = 4096
report         = 60
log-level      = 4
```

**server — 지사별 인스턴스** `multi-fec@server-<지사>`
```ini
mode   = server
listen = 203.0.113.5:50408      # 인스턴스마다 다르게
wg     = 127.0.0.1:51808        # 인스턴스마다 다르게 (= WG ListenPort)
key    = <PSK-지사>
# 운영은 client 와 같이 나머지 전부 명시
```

**relay — 단일 upstream** `multi-fec@relay`
```ini
mode          = relay
listen        = 0.0.0.0:443
upstream      = 203.0.113.5:443
key           = <PSK>
auth-interval = 60
sock-buf      = 4096
log-level     = 4
```

**relay — 키별 라우팅(서비스망 2단 방식)** `multi-fec@relay`
```ini
mode          = relay
listen        = 198.51.100.50:443
route-file    = /etc/multi-fec/routes
auth-interval = 60
sock-buf      = 4096
log-level     = 4
```
```
# /etc/multi-fec/routes
# to HQ for branch-17
<PSK-17>  203.0.113.5:50417
# to HQ for branch-18
<PSK-18>  203.0.113.5:50418
```

**relay — 한 호스트 IP 2개로 2개(테스트망 r 방식)** `multi-fec@relay-b`
```ini
mode           = relay
listen         = 192.0.2.117:443
upstream       = 203.0.113.5:443
upstream-local = 192.0.2.117
key            = <PSK>
auth-interval  = 60
sock-buf       = 4096
```

## 근거 자료

- `test-results/2026-10-05-vm-guard-calib/REPORT.md` §12·§14 (버퍼·지연), `raw/bufx_1017/` (1·2·4 MB 교차), `raw/tcpx_1017/` (TCP 1 vs 4 MB)
- CLAUDE.md §8(클라 멀티패스 정책 라우팅) · §9(relay 키별 라우팅) · §22-나(relay 세션 상한) · §23(PSK 로그) · §26(`--upstream-local`) · §27(`--accept-local`, `ipi_ifindex`=0)
- 회선 라우팅 실측(2026-10-18, 테스트망 r): 이 문서 §6·§7 표

## 13. 구현 메모 (설계와 달라진 점 · 구현 중 발견)

- **라우트 공유 판정은 다른 인스턴스의 설정이 아니라 기록 파일**(`/run/multi-fec/*.routes`)로 한다 — 실제로 건 것만 정확히 안다.
- **결함 수정(T6)**: 같은 `/32` 가 이미 있으면 "그대로 둔다"만 하고 기록하지 않아, 첫 인스턴스의 `--remove-routes` 가 두 번째 인스턴스가
  쓰는 라우트를 지웠다. 다른 인스턴스 기록이 있으면 함께 기록한다. 기록이 없는 같은 라우트(netplan 등)는 계속 기록하지 않는다.
- `via` 경로는 커널이 이미 그 인터페이스로 게이트웨이를 거쳐 갈 수 있으면(그 인터페이스의 default 존재) `/32` 를 만들지 않는다.
  같은 목적지를 두 인터페이스 모두 `/32` 로만 보내야 하면(둘 다 default 없음) 한 `/32` 가 한쪽만 가리키므로 오류로 안내한다.
- `--check` 추가 항목: listen IP 가 호스트에 있는지(고정 IP bind 실패 = exit 1 사례), path 소스 IP 존재 판정은 주소 목록 + `bind` 시험
  (127/8 처럼 목록에 없는 로컬 주소). 다른 설정 파일 중 `--config` 형식이 아닌 것(1.3.x env 파일, `netem.conf`)은 건너뛴다.
- `--route` 명령행 형식도 route-file 과 같은 꼬리(`via`/`gw`/`local`)를 받는다. 키 단어는 argv 에서 가린다.
- client 설정의 `wg` 는 `listen` 의 별칭이다(둘 다 쓰면 거부). relay 에 `wg` 는 거부.
- **같은 목적지 다회선(T5b)**: 두 경로가 `dev=ens18`/`dev=ens19` 로 갈리고 RUNNING. 첫 실행의 첫 30초 보고에서 owd 이상값
  (수십억 ms)이 한 번 나왔고 95초 재실행(보고 3회)에서는 정상(0.43~0.49 ms) — **재현 안 됨, 원인 미확인.** 경로별 tx/rx 가 엇갈리는
  현상(예: 590/295 · 297/590)은 1.3.6 에서도 같아 1.4.0 과 무관하다(서버의 duplicate 송신이 경로마다 더해진다).
- FIFO 자동 경로는 디렉터리가 없으면(유닛 밖 수동 실행) 경고 후 생략한다 — `create_fifo()` 가 실패 시 프로세스를 종료하기 때문.
- `mf-pair.sh` 는 지문을 `--check` 로 계산한다(키를 명령행에 올리지 않기 위해).
- **줄 끝 주석(태그 후 수정, 2026-10-19)**: `--path`·`--route` 값에서 공백 뒤 `#` 이후는 주석으로 버리고 경고한다. systemd `EnvironmentFile` 이
  줄 끝 주석을 값에 남기고, 1.3.x 가 포트 뒤를 무시했기 때문에 서비스 설정이 이 형태를 쓰고 있었다("모르는 단어 거부" 원칙의 예외).
