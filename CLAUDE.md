# multi-fec — 개발자 레퍼런스

## 작업 워크플로 (Claude)

- Claude가 생성한 PR은 별도 확인 없이 `dev` 브랜치로 **자동 머지**한다 (머지 방식: merge 커밋).
- 자동 머지 후 결과(머지 커밋 SHA)를 보고한다. CI가 구성되어 있으면 통과 확인 후 머지한다.
- **변경 이력은 `CHANGELOG.md`에 버전·날짜별로 기록**한다. 버전은 `common.h`의 `MULTI_FEC_VERSION`과 일치시키고, 기능/프로토콜/버그 수정처럼 동작에 영향 있는 변경은 버전을 올린 뒤(MAJOR=비호환·MINOR=기능추가·PATCH=버그) 새 섹션을 추가한다. 문서/테스트만 바뀌면 버전 유지하고 `[Unreleased]`에 날짜 항목만 누적한다. 상세 배경은 "버그 수정 이력" §에 두고 CHANGELOG는 요약+참조만. (규칙 전문은 CHANGELOG.md 상단)

### 테스트 환경 (실행은 테스트망, 빌드/바이너리는 sv1)

- **빌드·실행파일**: 빌드·개발·배포용 바이너리 작업은 모두 **`sv1`**(hostname `sv1xdnkr`, Ubuntu 24.04 x86_64, gcc 13.3.0)의 `~/multi-fec`에서 한다. macOS 로컬은 빌드 불가(Linux 전용 API). `make static-strip` → `multi-fec-dist`(정적·strip, GLIBC 의존성 없음). sv1은 각 테스트 호스트에 직접 접근 불가 → 전송은 sv1→로컬→호스트 경유.
  - 2026-07-02 wt5(wt5.xdn.kr)에서 sv1로 이전 완료. 이후 모든 작업은 sv1에서 수행. (구 wt5 환경은 폐기)
  - **sv1은 현재 셸이 도는 머신 자체**(`hostname`=`sv1xdnkr`, `/etc/hosts`에서 `127.0.1.1`로 해석). `ssh sv1`은 연결 거부되므로 SSH하지 말고 이 셸에서 직접 실행한다.
  - `--version` 표기: `common.h`의 `MULTI_FEC_VERSION`("1.0.0") + Makefile `git_version`이 `git describe --tags --dirty --always`로 넣는 실제 리비전 + 빌드시각. (구버전은 git 리비전만 표기했음)
  - 빌드: `make clean` 후 곧바로 `make -j$(nproc)` 해도 된다. (v1.0.3에서 `git_version.h`를 실제 파일 타깃으로 바꿔 병렬 빌드 경합을 없앴다 — §20-바. 그 전에는 `make git_version`을 먼저 실행해야 했다.)
  - 메모리·미정의동작 점검이 필요하면 `make asan` → `./multi-fec-asan` (테스트 스크립트에 `BIN=./multi-fec-asan`).
- **실행(테스트)**: 실제 실행·측정은 **테스트망**에서. Server `s.xdn.selfinet.com`(**리슨은 사설 `192.168.100.84:443` 전용** — 2026-08-05 `192.168.200.254`에서 이전. `ens18`에 `.84/24`를 추가해 c·r과 같은 `/24`에 올렸다. 공인 218.154.1.134 로는 서비스하지 않는다), Client `c.xdn.selfinet.com`(Atom N2600, 192.168.100.141), Relay `r.xdn.selfinet.com`(LAN `192.168.100.85` + `192.168.100.86` static). 세 호스트 nopasswd sudo, 배포 바이너리 `/usr/sbin/multi-fec-dist`, systemd `multi-fec-{server,client,relay}`.
- **경로 구성 (2026-08-02 개편)**: **2경로 모두 릴레이 경유**. 릴레이 인스턴스가 2개여야 한다 — 한 프로세스가 두 IP를 받으면 클라이언트 mud 의 단일 UDP 소켓 때문에 두 경로가 같은 세션·같은 upstream 소켓으로 합쳐진다.
  ```
  path[0]  c ──► r 192.168.100.85:443 (multi-fec-relay)   ──► s 192.168.100.84:443
  path[1]  c ──► r 192.168.100.86:443 (multi-fec-relay@b) ──► s 192.168.100.84:443
  ```
  **c·r·s 가 모두 같은 `/24` 에 있어 데이터 경로 전체가 온링크다 — gw 를 전혀 지나지 않는다**
  (2026-08-05 이전. MAC 으로 확정: 프레임이 `r ens18 bc:24:11:ad:10:a5 → s ens18
  bc:24:11:c5:57:c9` 직결이고 gw MAC `bc:24:11:bb:7b:9c` 는 나타나지 않는다).
  ⚠️ 따라서 **`s` 의 `ens18` RX+TX 는 더 이상 gw 부하 대리지표가 아니다** — 규칙 0 참고.
  두 경로가 릴레이 호스트 `r` 과 같은 스위치·L2 를 공유하므로 **호스트·회선 장애는 분리되지
  않는다**(프로세스 장애만 분리). 이전 구성보다 공유 구간이 오히려 늘었다.
- **터널**: multi-fec 경유 WG는 `starlink-fec`(s=10.9.10.1, c=10.9.10.2). 직결 `starlink-xdn`(10.9.9.x)은 미경유 — 측정에 쓰지 말 것.
- **netem**: `mf-netem.service`(systemd oneshot, c·r 양쪽 enabled)로 **`c↔r` 구간**에 경로별 적용. 현재 값 **path[0](.85) 편도 25ms/5%, path[1](.86) 편도 30ms/2%** (= RTT 50/60ms, **양방향**). 값 변경은 `/etc/multi-fec/netem.conf` 수정 후 c·r **양쪽** `systemctl restart mf-netem`. 링크 플랩 시 qdisc 가 사라지므로 재적용 필요.
  > ⚠️ **u32 필터는 dst IP 뿐 아니라 `dport 443` 까지 매치한다.** 다른 포트로 프로브를 쏘면 band 3(무임피어먼트)로 빠져 **netem 을 전혀 받지 않는다** — 측정이 조용히 무의미해진다. 프로브를 실제 경로와 같은 조건에 두려면 `pref 2` 로 프로브 포트용 필터를 추가하고 끝나면 지운다(`test-results/2026-08-03-pathcorr-relaycut/pc_setup.sh`).
- **운영 변경 시**: mode 전환은 `.service` ExecStart `--mode N` 하드코딩(FIFO는 mode2 미지원)이라 sed+daemon-reload+restart. 측정 후 **반드시 mode1+원본 바이너리로 원복**(unit 백업, 바이너리 `.bak-precauchy` 보관).

#### 테스트망 구성도 · 라우팅 (2026-08-03 고정)

```
                        ┌──────────────────────────────┐
                        │        gw.xdn.kr             │  라우터 (**SNAT 함** — 아래)
                        │  192.168.100.1               │  c·r·s 가 전부
                        │  192.168.200.1               │  ens18 한 포트에 물림
                        └──────────────────────────────┘  → r↔s 는 헤어핀(2회 계상)
                                     │ ens18
                    ┌────────────────┴─────────────────┐
        192.168.100.0/24                        192.168.200.0/24
              │                                        │
      ┌───────┴────────┐                               │
  ┌───┴────┐      ┌────┴─────┐                   ┌─────┴──────┐
  │   c    │      │    r     │                   │     s      │
  │ test3  │      │  infra   │                   │xdn-temp-pop│
  │ Atom   │      │ .85 .86  │                   │ .84 (+.254)│
  │ .141   │      │ (static) │                   │            │
  └────────┘      └──────────┘                   └────────────┘
   +.50.1/24                                      +ens19 218.154.1.134 (공인)
   +enp3s0 192.168.3.100                          +ens20 1.220.235.146/29

  c ↔ r : 같은 /24 온링크 → gw 미통과 (스위치 내부)
  r ↔ s : 2026-08-05 부터 s 가 .84/24 를 가져 **온링크 → gw 미통과**
          (.254 는 남겨뒀지만 아무것도 그 주소를 쓰지 않는다)
```

**데이터 경로**

```
[앱] → wg starlink-fec 10.9.10.2 (c) ←→ 10.9.10.1 (s)
         └ Endpoint = 127.0.0.1:51821   ← 루프백. WG 가 자기 터널에 못 들어가는 안전장치
       → multi-fec client -l 127.0.0.1:51821   (duplicate, mode 1, -f 5:1,20:4, --mtu 1350)
           ├ path[0] → r 192.168.100.85:443  (multi-fec-relay)    ┐ 온링크
           └ path[1] → r 192.168.100.86:443  (multi-fec-relay@b)  ┘ gw 미통과
               → upstream → s 192.168.100.84:443                  ← 온링크(gw 미통과)
                   → multi-fec server --wg 127.0.0.1:51821 → wg 10.9.10.1
```

**라우팅 테이블** — ★ 는 [규칙 2](#테스트망-절대-규칙) 관련(하부 전송망을 터널로 보내지 않기 위한 것)

```
# c ── 192.168.100.141
default            via 192.168.100.1  dev enp2s0        proto static
192.168.3.0/24                        dev enp3s0        온링크        (테스트망 무관)
192.168.200.0/24   via 192.168.100.1  dev enp2s0                     ★ 터널 아님 (이제 미사용)
192.168.100.0/24                      dev enp2s0        온링크        → r .85/.86
192.168.50.0/24                       dev enp2s0        온링크        → .50.10
10.9.10.0/24                          dev starlink-fec  온링크
10.9.9.0/24                           dev starlink-xdn  온링크
<인터넷 프리픽스 48개> via 10.9.10.1  dev starlink-fec  metric 10    ← 제품 용도

# r ── 192.168.100.85 / .86   (터널 인터페이스 없음)
default            via 192.168.100.1  dev ens18         proto static  ★ static (DHCP 아님)
192.168.100.0/24                      dev ens18         온링크 src .85
172.17.0.0/16 / 172.18.0.0/16         dev docker0 / br-*              ← Docker, 무관

# s ── 192.168.100.84 (+ 192.168.200.254)   ← 2026-08-05 .84 추가
default            via 218.154.1.254  dev ens19         metric 1      ← 공인, gw 아님!
default            via 1.220.235.145  dev ens20         metric 2
192.168.100.0/24                      dev ens18         온링크 src .84 ★ 터널 아님
                                                        (구 `via 192.168.200.1` 정적 라우트는 삭제)
192.168.200.0/24                      dev ens18         온링크
192.168.50.0/24    via 10.9.10.2      dev starlink-fec  metric 10     ← c 뒤 LAN (터널 유지)
10.9.10.0/24                          dev starlink-fec  온링크
10.9.9.0/24                           dev starlink-xdn  온링크
218.154.1.0/24 / 1.220.235.144/29     dev ens19 / ens20
```

> ⚠️ **gw 는 `NAT 없음`이 아니다.** 2026-08-05 `s` 에서 수동 캡처로 확인했다 — gw 를 경유하던
> 시절 `r`(`192.168.100.85:54374`)가 보낸 패킷이 `s` 에는 `192.168.200.1:54374`(gw 주소, 포트
> 보존)로 도착했다. 즉 **서브넷 간 트래픽은 SNAT 된다.** 지금은 전 경로가 온링크라 해당되지
> 않지만, gw 를 경유하는 구성으로 되돌리면 **`s` 는 릴레이 소스 IP 를 볼 수 없다**(경로별 계측
> 불가, `--upstream-local` 효과도 `s` 에서 안 보임).
>
> ⚠️ **`s` 의 default 는 gw 가 아니라 공인 `ens19`** 다. 그래서 `192.168.100.0/24` 라우트를
> **지우기만 하면 사설 대역이 인터넷으로 새어 나간다.** 반드시 `ip route replace` 로 gw 경유를
> 먼저 넣을 것. (`c` 는 default 가 gw 라 해당 없음)

**규칙 2 검증 — 12개 조합 전부 "터널 아님"이어야 한다**

| 출발＼목적지 | c .141 | r .85 | r .86 | s .254 |
|---|---|---|---|---|
| **c** | (self) | 온링크 | 온링크 | 온링크 (s .84) |
| **r** | 온링크 | (self) | (self) | 온링크 (s .84) |
| **s** | 온링크 | 온링크 | 온링크 | (self) |

```bash
# 설정 변경 후 반드시 실행 (트래픽 안 만듦). 전부 "위반 0" 이어야 한다
for src in c r s; do ssh $src.xdn.selfinet.com "n=0
  for ip in 192.168.100.141 192.168.100.85 192.168.100.86 192.168.100.84; do
    ip route get \$ip | head -1 | grep -qE 'starlink|tun|wg' && n=\$((n+1)); done
  echo \"[$src] 위반 \$n 건\""; done
```

> ⚠️ **TCP 양방향은 `iperf3 --bidir` 로 재지 말 것** — iperf 3.9 TCP 경로에서 합계가
> 36배 붕괴한다(1.8 Mbps). 같은 조건에서 **별도 인스턴스 2개는 41.9 Mbps**. UDP `--bidir` 은
> 정상이다. 2026-08-06 확인.

> ⚠️ **호스트 타임존이 다르다** — `r` 만 UTC, `c`·`s` 는 KST(시계 자체는 일치).
> `journalctl` 을 호스트 간에 눈으로 대조하면 **9시간 어긋나 보인다.** 로그를 짝지을 때
> `journalctl --utc` 로 정규화할 것.

**부팅 자동기동** (전부 `enabled` — 2026-08-03 고정)

| 호스트 | 유닛 |
|---|---|
| c | `multi-fec-client`, `wg-quick@starlink-fec`, `mf-netem` |
| r | `multi-fec-relay`, `multi-fec-relay@b`, `mf-netem` |
| s | `multi-fec-server`, `wg-quick@starlink-fec` |

2026-08-03 이전에는 c·s 의 `multi-fec-*`·`wg-quick@starlink-fec` 가 **`disabled` 상태로 수동
기동만 돼 있어 재부팅하면 터널 체인이 안 올라왔다.** `r` 의 `.85` 도 DHCP 산물이어서, gw 가 다른
장비에 배정하면 릴레이 `LISTEN=192.168.100.85:443` 이 바인딩 실패로 기동을 거부하고 path[0] 이
사라졌다 → **static 전환.** 상세는 `test-results/2026-08-03-pathcorr-relaycut/REPORT.md` §5.

> **`r` 에 `netplan apply` 할 때**: r 은 `ens18` 로만 접근 가능하고 콘솔이 없다 — 설정이 틀리면
> 원격 복구가 불가능하고 릴레이 2개가 동시에 죽는다. `systemd-run --on-active=180` 으로 백업
> 복원을 예약해두고 apply 한 뒤, 접속 확인 후 예약을 취소한다. `netplan try` 는 TTY 확인이
> 필요해 비대화형에서는 항상 되돌아가므로 쓸 수 없다. → REPORT §5-3

**기준 실측값** (이탈하면 구성이 바뀐 것이다)

| 구간 | RTT | 손실 |
|---|---|---|
| WG 터널 `10.9.10.2 ↔ 10.9.10.1` | **54.1 ms** | 0% |
| s → r `.85` | **0.53 ms** | 0% |
| s → r `.86` | **0.64 ms** | 0% |
| s → c `.141` | **1.12 ms** | 0% |
| 유휴 시 s `ens18` | — | RX/TX 약 120/210 kbps |

> 2026-08-05 이전 값(gw 헤어핀 시절): s→r 1.00 ms, c→s `.254` 1.30 ms, WG 54.3~54.9 ms.
> 온링크 전환으로 하부망 RTT 가 약 절반이 됐다.

**미확인 장비 2대** — `192.168.100.82`(LG전자 OUI, s 의 ens18 이웃), `192.168.50.10`(Intel OUI,
c 의 `.50.1/24` 유일 호스트). gw 기저 부하와 관련 가능.

#### 테스트망 절대 규칙

**규칙 0 — 테스트망은 `c`·`r`·`s` 가 전부 `192.168.100.0/24` 인 단일 네트워크다.
gw 는 테스트망 데이터를 나르지 않는다.**

c·r 의 default route 가 `192.168.100.1`(gw)이지만 **longest prefix match** 로 `/24` 온링크가
먼저 걸리므로 **테스트망 목적지에는 default 가 조회조차 되지 않는다.** gw 를 지나는 것은
테스트망 밖으로 나가는 관리·업데이트 트래픽뿐이다.

```
목적지 192.168.100.84  →  192.168.100.0/24 dev <if> 온링크   ← /24, 더 구체적 → 채택
                          0.0.0.0/0 via 192.168.100.1        ← /0, 최후수단 → 미조회
```

**새 지표 (2026-08-05 `mf_gwguard.sh` 재작성)** — 프록시를 버리고 **제약을 직접 잰다.**
2026-08-02·08-03 두 사고의 공통 원인이 "대리지표가 조용히 무효해진 것" 이었기 때문이다.

| 신호 | 임계 | 근거 |
|---|---|---|
| `c` 전체 CPU busy | **62%** | 용량 모델의 실측 포화점 (HT 실효 2.5코어) |
| `r`·`s` 전체 CPU busy | 75% | VM, 여유 있음. 병목이 옮겨가도 눈이 멀지 않게 |
| **최고 1코어 busy** | **85%** | multi-fec 단일 스레드 + 수신 softirq cpu2 고정. **대개 이게 먼저 걸린다.** 90 은 붕괴(손실 14%, 1코어 85.7%)를 놓쳤고 80 은 정상 구간(79.2%)에 붙어 오탐한다 — 2026-08-06 계단 실측 |
| iface RX+TX | 400 Mbps | 증폭 루프 백스톱 — 2026-08-03 의 800 Mbps 류를 즉시 잡는다 |

3회 연속 초과에서 트립. `precheck` 로 **자기 전제를 먼저 확인**하고(호스트·인터페이스·
온링크 12조합), 전제가 깨지면 감시를 시작하지 않는다. `budget` 은 용량 모델로 판정한다
(⚠️ 인자가 **양방향** Mbps 다 — 구 gw 버전은 각 방향이었다).

아래 gw 기록은 gw 경유 구성으로 되돌릴 때만 유효하다.

**절차 교훈은 토폴로지와 무관하게 유효하다** — gw `ens18` 방향당 70 Mbps 시절, 손계산으로
"여유롭다" 판단하고 가드 없이 돌려 **gw 가 800 Mbps 를 넘겼다**(2026-08-03, 원인 미확정,
REPORT §3). 교훈은 계산이 아니라 절차였다: ① 트래픽 생성 **전에** 가드를 띄운다 ② 가드가
없으면 시작하지 않는다 ③ 대리지표는 반드시 실제 계측점과 한 번 대조한다. 새 지표를 정할 때도
같다.

**규칙 1 — 트래픽 테스트는 WG IP 사이에서만.** `c 10.9.10.2 ↔ s 10.9.10.1`. c/r/s 의 실제 IP로
직접 프로브를 쏘지 않는다(하부 전송망을 건드려 아래 루프 조건에 노출된다).
`starlink-xdn`(10.9.9.x)은 직결이라 multi-fec 을 안 타므로 **측정 금지**.

**규칙 2 — c/r/s 의 IP 는 절대 터널로 라우팅하지 않는다.** 터널을 *실어 나르는* 주소를 터널
안으로 보내면 multi-fec 이 자기 전송을 삼키고 `duplicate` 가 **한 바퀴마다 2배**로 키운다.
2026-08-03 에 WG PostUp 이 심던 `192.168.200.0/24`(c) / `192.168.100.0/24`(s) 를 제거했다.
gw 경유 라우트는 **netplan** 에 둔다 — WG PostUp 에 넣으면 WG 가 내려갈 때 PostDown 이 지워
서버가 릴레이에 못 닿는다(**multi-fec 은 WG 와 독립**이다).

## 프로젝트 개요

UDPspeeder V2 FEC + glorytun mud_lite 멀티패스 + GFW 난독화를 결합한 UDP 프록시.
WireGuard와 네트워크 사이에서 동작하며 FEC 복구, 다중 경로 전송, 심층 패킷 검사 우회를 제공한다.

```
[WireGuard 클라이언트]
        │ UDP
[multi-fec 클라이언트] ──path1(직접)──────────────▶ [multi-fec 서버]
                       ──path2(POP 경유)──▶ [릴레이] ──▶      │ UDP
                                                        [WireGuard 서버]
```

---

## 소스 파일 구조

| 파일 | 역할 |
|------|------|
| `main.cpp` | CLI 파싱, 초기화, 모드 분기, FIFO 런타임 채널 |
| `mf_client.cpp` | 클라이언트 이벤트 루프 (FEC 인코드 + mud_lite 송신) |
| `mf_server.cpp` | 서버 이벤트 루프 (mud_lite 수신 + FEC 디코드) |
| `mf_relay.cpp` | 릴레이(POP) 이벤트 루프 (투명 UDP 포워더) |
| `obfs.cpp / obfs.h` | GFW 난독화 계층 (QUIC/TLS 위장 + HMAC 인증) |
| `mud_lite.c / mud_lite.h` | glorytun 멀티패스 경로 관리 (RTT/손실 기반) |
| `mf_common.h` | 공유 타입: PathSpec, multipath_mode_t, session_id, route_entry_t |
| `siphash.h` | SipHash-2-4 구현 (obfs HMAC용) |
| `rnlc.cpp / rnlc.h` | RNLC(Random Linear Network Coding) FEC 모드 — `--mode 2` (GF(256) + 가우스 소거) |

upstream 코드 (수정 없음): `fec_manager`, `lib/fec`, `lib/rs`, `connection`, `packet`, `misc`, `log`, `common`

---

## 핵심 설계

### 1. 동작 모드

```c
// common.h
enum program_mode_t { unset_mode=0, client_mode, server_mode, relay_mode };
```

- **client** (`-c`): WireGuard 로컬 포트 수신 → FEC 인코드 → obfs → mud_lite 송신
- **server** (`-s`): mud_lite 수신 → obfs 디코드 → FEC 디코드 → WireGuard 포워드
- **relay** (`-r`): 투명 UDP 포워더. FEC/obfs 미처리, raw bytes 중계

### 2. session_id (다중 POP 집계)

```c
#define SESSION_ID_LEN 8
extern uint8_t g_session_id[SESSION_ID_LEN];  // /dev/urandom, 클라이언트 시작 시 생성
```

클라이언트가 `/dev/urandom`에서 8바이트 생성 후 모든 FEC 패킷 앞에 첨부.
서버는 `unordered_map<uint64_t, address_t> g_session_to_addr`로 session_id → 최초 소스 주소 매핑.
POP 경유 여부와 무관하게 동일 클라이언트를 단일 FEC 세션으로 집계한다.

와이어 포맷 (클라이언트 → 서버):
```
[8B session_id][obfs_header][FEC payload]
```

릴레이는 session_id를 해석하지 않고 raw bytes를 그대로 통과시킨다.

### 3. obfs 계층 (obfs.cpp)

**QUIC 모드** (기본, `--obfs-mode quic`):
```
[1B flags: 0x40-0x7F][8B HMAC token][1B pad_len][payload][padding]
헤더 크기: OBFS_HEADER_QUIC = 10
```

**TLS 모드** (`--obfs-mode tls`):
```
[0x17][0x03][0x03][2B length][8B HMAC token][1B pad_len][payload][padding]
헤더 크기: OBFS_HEADER_TLS = 14
```

디코드 시 첫 바이트로 자동 판별:
- `(p[0] & 0xC0) == 0x40` → QUIC
- `p[0] == 0x17` → TLS

HMAC 토큰: `SipHash-2-4(slot, PSK)`, 슬롯 = `time(NULL) / 30`.
검증 시 현재 슬롯 ±1 허용 (시계 오차 대응).

패딩 버킷: `{300, 500, 700, 900, 1100, 1300, 1400, 1500}` bytes — 패킷 크기 분포를 정규화.
1500B 초과 시 마지막 버킷(1500B) 반환 → pad_len < 0 → 0으로 클램프 → 패딩 없이 원본 크기 전송.

**QUIC Long Header Initial 핸드쉐이크 시뮬레이션** (`obfs_encode_initial`):

RFC 9000 §14.1 준수: 1200B 고정 크기 패킷으로 DPI가 QUIC로 분류하게 한다.
```
p[0]     = 0xC1   LongHeader|Fixed|Initial|PN_LEN=2
p[1-4]   = 0x00000001   QUIC version 1
p[5]     = 0x08   DCID length=8
p[6-13]  = HMAC token   (DCID 필드를 인증에 활용)
p[14]    = 0x08   SCID length=8
p[15-22] = random (p[15]=0x00 Client Initial / 0xFF Server Initial)
p[23]    = 0x00   Token length=0
p[24-25] = 0x44 0x96   pkt_len varint=1174
p[28-1199] = PADDING frames
```
`SCID[0]=0xFF`(Server Initial) 수신 시 클라이언트가 조용히 폐기 — 루프 방지.
`obfs_decode()` 반환값 `OBFS_DECODE_INITIAL(-2)` → mud_lite가 Server Initial 자동 응답.

HMAC 실패 시 동작 (우선순위 순):
1. `--decoy ip:port` 지정 시: raw 패킷을 decoy 서버(QUIC/HTTPS)로 포워딩 → 응답을 프로버에게 중계
2. `--decoy` 미지정 시: **내장 QUIC Server Initial** 1200~1455B 응답 (`probe_respond_builtin`)
   ```
   0xC1 0x00000001 DCID(8B=HMAC token) SCID(8B, [0]=0xFF) PADDING...
   RFC 9000 §17.2.2 준수, SCID[0]=0xFF → Server Initial 마커
   + 0~255B 랜덤 추가 (QUIC coalesced packet 영역, 크기 다양화)
   ```

**decoy 세션 관리** (`mf_server.cpp`, `mf_relay.cpp` 공통):
```cpp
struct decoy_sess_t {
    address_t prober_addr;  // GFW 프로버 주소
    int       decoy_fd;     // decoy 서버로 connect된 UDP 소켓
    ev_io     watcher;
    time_t    last_active;
};
// 프로버 주소 → 세션 (10초 idle → 자동 제거)
unordered_map<address_t, decoy_sess_t *> g_decoy_map;
```

서버의 `decoy_sess_t`에는 `listen_fd`(mud fd / TOTP fd 선택용)가 추가로 있음.
릴레이는 단일 `g_listen_fd`를 사용하므로 불필요.

트래픽 흐름 (`--decoy` 지정 시):
```
GFW 프로버 ──UDP :443──▶ multi-fec 서버/릴레이 (HMAC 실패) ──UDP :8443──▶ nginx QUIC
GFW 프로버 ◀──────────────────── sendto(prober_addr) ◀────── decoy_io_cb ◀──
```

트래픽 흐름 (`--decoy` 미지정, 내장 응답):
```
GFW 프로버 ──UDP :443──▶ multi-fec (HMAC 실패)
GFW 프로버 ◀── QUIC Server Initial 1200~1455B ── probe_respond_builtin()
```

### 4. mud_lite 멀티패스 (mud_lite.c)

glorytun의 경로 관리 코드를 단독 모듈로 분리. 단일 UDP 소켓 + `IP_PKTINFO`로 인터페이스별 소스 IP 제어.

**경로 상태 전이**:
```
PROBING → RUNNING → LOSSY
                 → DEGRADED
                 → WAITING
```
- `RUNNING`: 데이터 전송 가능
- `LOSSY`: tx.loss > loss_limit → 데이터 전송 차단 (probe만 유지)
- `DEGRADED`: 생존 타임아웃(`rx.time` 기준 1초 무수신) 또는 probe 무응답. **RTT 기반 판정은 없다** — `mud_path_update()`에 RTT 분기가 존재하지 않고, `mud_send_next_peer()`의 aggregate 분배도 `tx.rate`만 본다
- `WAITING`: PASSIVE 경로 beat 타임아웃

**LOSSY 판정 공식**:
```c
// mud_update_rl() — 1초마다 갱신
tx.loss = (tx_acc - rx_acc) * 255U / tx_acc

// mud_update_path() — 100ms마다 확인
if (path->tx.loss > path->conf.loss_limit) → MUD_LOSSY
```

**loss_limit 수치**:
| 경로 종류 | 기본값 | LOSSY 임계 손실률 |
|-----------|--------|------------------|
| 설정 경로 (`mud_set_path`) | 255 | 100% (사실상 미적용) |
| PASSIVE 경로 (`mud_recv`) | 200 | 78.4% |
| 서버 probe 응답 수신 시 | 서버값으로 덮어씀 | — |

클라이언트가 서버 probe 응답을 받으면 `path->conf.loss_limit = msg->loss_limit`로 갱신됨.
서버 PASSIVE loss_limit=200이 클라이언트 설정 경로에 적용되는 효과.

**LOSSY 비대칭성**:
- 클라이언트 path LOSSY → 클라이언트→서버 전송 차단
- 서버는 독립적으로 path 상태 판단 → 서버→클라이언트는 별개
- `mud_recv()`는 path 상태와 무관하게 수신 허용 (송신만 차단)

**rate / window 메커니즘**:
```c
// mud_update_rl() branch 1 (rx_dt >= 1s): rate 재계산
path->tx.rate = max(7/8 × rx_bytes/rx_dt, 1,000,000)  /* min 1MB/s */

// mud_update_rl() branch 2 (rx_dt < 1s): rate 점진 증가
path->tx.rate += path->tx.rate / 10   // +10% per probe ACK

// mud_update_window() — 1ms마다 실행
mud->window += mud->rate × elapsed
window_max  = max(rate × 100ms, 524,288)  /* min 512KB */
mud->window = min(mud->window, window_max)
```
`mud->window < pkt_size`이면 `mud_send()` → EAGAIN.
`mud_send_all()`은 window를 논리적 1패킷만큼만 차감 (N경로 전송해도 N배 차감 안 함).

**경로 초기 rate**:
```c
// mud_set_path() — 신규 경로 생성 시
path->tx.rate = tx_max_rate ? tx_max_rate : 10,000,000  /* 10MB/s */
```

**PASSIVE 경로 beat 수정** (다운스트림 비대칭 수정):
```c
// mud_recv()에서 PASSIVE 경로 생성 시
if (!path->conf.beat)       path->conf.beat       = mud_random_beat(path);  /* 80–120ms 랜덤 */
if (!path->conf.loss_limit) path->conf.loss_limit = 200;
```
beat=0이면 패킷 수신 후 즉시 WAITING으로 전환되어 서버→클라이언트 방향에 해당 경로 사용 불가.
80~120ms 범위의 랜덤 beat를 설정해 서버도 PASSIVE 경로로 능동 송신 가능하게 하고,
probe 주기 고정 패턴을 방지한다.

**송신 함수 비교**:

| 함수 | 모드 | 동작 |
|------|------|------|
| `mud_send()` | failover | 최적 단일 경로에 전송 |
| `mud_send_all()` | duplicate | 모든 RUNNING 경로에 동일 패킷 |
| `mud_send_next(mud, data, size, 1)` | aggregate | 가중 라운드로빈으로 1개 경로 선택 |
| `mud_send_next(mud, data, size, N)` | aggregate-duplicate | 가중 선택 N개 경로에 전송 |

모든 함수에서 window는 논리적 1패킷만 차감 (N경로 전송해도 N배 차감 안 함).

**duplicate 모드** (`mud_send_all`):
```c
// RUNNING 상태인 모든 경로에 동일 패킷 전송
// LOSSY/DEGRADED/WAITING 경로는 제외
for (unsigned i = 0; i < mud->capacity; i++) {
    if (path->status != MUD_RUNNING) continue;
    ...
}
```

**aggregate / aggregate-duplicate 모드** (`mud_send_next`):
```c
// 1. 모든 RUNNING 경로에 tx.rate 비례 크레딧 적립
for each RUNNING path: path->agg_credit += path->tx.rate;

// 2. 크레딧 최대 경로 순으로 dup_count개 선택 후 전송
for d in 0..dup_count:
    best = argmax(agg_credit, RUNNING paths)
    best->agg_credit -= total_rate   // 균등화
    mud_send_path(best, ...)

// 3. window 1패킷만 차감
```

**dedup** (수신 측 중복 제거):
```c
#define MUD_DEDUP_SIZE 128   // 링버퍼 엔트리 수
#define MUD_DEDUP_TTL  (500 * MUD_ONE_MSEC)  // 500ms
// 패킷 내장 전송 타임스탬프(8B)로 동일성 판별
```

### 5. 릴레이 (mf_relay.cpp)

클라이언트 (src_ip, src_port) 단위 세션 관리:

```cpp
struct relay_session_t {
    address_t              client_addr;   // 클라이언트 주소
    int                    upstream_fd;   // 서버 방향 UDP 소켓 (connect됨)
    ev_io                  upstream_watcher;
    my_time_t              last_active;
    const struct obfs_ctx *route_obfs;   // 세션에 매칭된 키의 obfs. NULL=투명 모드
};
unordered_map<address_t, relay_session_t *> g_addr_to_sess;  // 클라이언트 주소 → 세션
unordered_map<int,       relay_session_t *> g_fd_to_sess;    // upstream_fd → 세션
```

세션 타임아웃: 60초 idle → 제거 (ev_timer 10초 주기).

**단일 upstream 모드** (`-k` + `--upstream` 지정 시):
```cpp
// obfs_decode()로 HMAC만 검증, decoded 결과는 버림
// 서버로는 원본 raw bytes 전달 (서버가 다시 decode)
// HMAC 실패 → --decoy 지정 시 decoy 포워딩, 미지정 시 내장 QUIC Server Initial
```

**키별 upstream 라우팅 모드** (`--route` 지정 시):

`-k`/`--upstream` 없이 `--route "key ip:port"` 를 하나 이상 지정하면 활성화.

```cpp
// mf_common.h
struct route_entry_t {
    char            key_str[1000];
    address_t       upstream_addr;
    struct obfs_ctx obfs;       // key_str로 초기화된 HMAC 컨텍스트
};
extern std::vector<route_entry_t> g_routes;

// 라우팅 결정 (신규 세션)
for (const route_entry_t &route : g_routes) {
    if (obfs_decode(&route.obfs, ...) > 0 || == OBFS_DECODE_INITIAL)
        → upstream = route.upstream_addr  (첫 매칭 사용)
}
// 모두 불일치 → decoy 또는 내장 QUIC Server Initial
```

**세션 키 고정 동작**:
- 신규 세션: 첫 패킷의 HMAC으로 키와 upstream을 결정해 `route_obfs`에 저장
- 기존 세션: 저장된 `route_obfs`로 이후 모든 패킷 재검증
- 동일 (src_ip, src_port)에서 다른 키 패킷 → HMAC 실패 → decoy 또는 내장 QUIC Initial
  (의도된 동작: 세션은 최초 키로 고정, 재협상 없음)

```bash
# 사용 예: keyA → 서버1, keyB → 서버2
multi-fec -r -l 0.0.0.0:443 \
    --route "keyA 1.2.3.4:443" \
    --route "keyB 5.6.7.8:443"
```

### 6. FIFO 런타임 커맨드

`--fifo PATH` 지정 시 ev_io watcher로 libev에 등록.
지원 명령 (`misc.cpp:handle_command`):

| 명령 | 범위 |
|------|------|
| `fec x:y` | FEC 비율 즉시 변경 |
| `mtu N` | FEC 패킷 MTU (100–2000) |
| `mode 0\|1` | FEC 모드 전환 |
| `timeout N` | FEC flush 대기 (ms) |
| `queue-len N` | FEC 인코드 큐 길이 |

`multipath-mode` 변경은 **FIFO 미지원** — 재시작 필요.

### 7. TCP 재전송과 FEC/duplicate의 관계

FEC + duplicate는 **multi-fec ↔ 서버 간 UDP 구간**만 보호한다.
TCP 재전송은 그 위 계층(WireGuard 터널 내부)에서 발생한다.

```
[iperf3 TCP] → [WireGuard 터널] → [multi-fec] ──UDP── [서버]
     ↑                                   ↑
  TCP 재전송                        mud EAGAIN 드롭
  (FEC 보호 범위 밖)                (FEC 보호 범위)
```

TCP 재전송 주요 원인:
1. **mud EAGAIN**: window_max < 순간 전송량 → 실제 드롭 → TCP 재전송
2. **FEC 그룹 reordering**: 복구 지연된 그룹이 다음 그룹보다 늦게 도착 → TCP가 손실로 판단 → fast retransmit
3. **시작 100ms**: `mud->window_time=0`이면 window=0으로 초기화 → 첫 번째 `mud_update_window()` 호출 전까지 모든 전송 EAGAIN

### 8. WireGuard MTU 설정

WireGuard MTU를 기본값(1420)으로 두면 multi-fec 오버헤드(~50B) 추가 후 UDP payload가 1490B로 경로 MTU(1472B)를 초과해 IP 단편화 발생.

```
WireGuard 패킷(1420B) + obfs TLS 헤더(14B) + mud 헤더 = ~1490B > 1472B → 단편화
```

**권장 WireGuard MTU: 1300**
```ini
# /etc/wireguard/wg0.conf
[Interface]
MTU = 1300
```
단편화 제거 후 실측 throughput 약 37% 향상 (20.7 Mbps → 28.3 Mbps).

---

## CLI 옵션 레퍼런스

### 모드 선택 (필수, 셋 중 하나)

| 옵션 | 설명 |
|------|------|
| `-c` | 클라이언트 모드 |
| `-s` | 서버 모드 |
| `-r` | 릴레이(POP) 모드 |

### 공통 옵션

| 옵션 | 값 범위 | 기본값 | 설명 |
|------|---------|--------|------|
| `-l ip:port` | — | 필수 | 로컬 리슨 주소. 클라이언트=WG 프록시포트, 서버=리슨포트 |
| `-k keystring` | 문자열 최대 999자 | — (**필수**) | PSK. client/server는 필수(`--disable-obfs` 시 면제) — 미지정 시 기동 거부. 릴레이는 선택(없으면 투명 중계) |
| `--obfs-mode M` | `quic` \| `tls` | `quic` | 패킷 위장 모드 |
| `--disable-obfs` | — | 비활성 | obfs 완전 비활성화 (테스트용) |
| `--fifo PATH` | 파일경로 | 없음 | 런타임 커맨드 FIFO |
| `--report N` | `1`–∞ (초) | `0` (off) | 통계 리포트 주기 |
| `--log-level N` | `0`–`6` | `4` | 0=fatal 1=error 2=warn 3=info 4=info+ 5=debug 6=trace |
| `--sock-buf N` | `10`–`10240` (kB) | OS 기본값 | UDP SO_SNDBUF/SO_RCVBUF 크기 |
| `--auth-interval N` | `30`–∞ (초) | `30` | HMAC 토큰 슬롯 길이. 클라이언트/서버 양쪽 동일 설정 필수. 길수록 슬롯 경계 탐지 어려움. 권장: `60` |

### 클라이언트 전용

| 옵션 | 값 범위 | 기본값 | 설명 |
|------|---------|--------|------|
| `--path L:R:P` | IP:IP:포트 | 필수 | 멀티패스 경로. 반복 가능. L=소스IP(0.0.0.0=자동), R=서버IP, P=포트(1–65535) |
| `--multipath-mode M` | 아래 참조 | `failover` | 멀티패스 동작 모드 선택 |
| `--dup-factor N` | `1`–`8` | `2` | aggregate-duplicate에서 패킷당 전송 경로 수. 경로 수 초과 시 자동 클램프. |
| `--port-hop-interval N` | `0`, `30`–∞ (초) | `0` (비활성) | TOTP 포트 호핑 슬롯 길이. 0=비활성. 최소 30초 |

**multipath-mode 모드별 동작**:

| 모드 | pref | 동작 | 처리량 | 가용성 |
|------|------|------|--------|--------|
| `failover` | 0,1,2… | 최우선 경로만 사용, 장애 시 다음 경로 | 단일 경로 | Active-Standby |
| `duplicate` | 모두 0 | 모든 경로에 동일 패킷 동시 전송 | 단일 경로 (중복) | 최고 |
| `aggregate` | 모두 0 | 경로별 다른 패킷 분배 (가중 라운드로빈) | **경로 합산** | 단일 경로 수준 |
| `aggregate-duplicate` | 모두 0 | 패킷당 `--dup-factor`개 경로에 전송 | 집계 효과 | 집계+이중화 혼합 |

> 경로 장애·지연차 상황에서의 모드별 실측 거동과 선택 지침은 §21-다 참고.

```
failover            → pref = 0, 1, 2, ...
duplicate           → pref = 0, 0, 0, ...  모든 경로에 동일 패킷
aggregate           → pref = 0, 0, 0, ...  경로별 다른 패킷 (가중 라운드로빈)
aggregate-duplicate → pref = 0, 0, 0, ...  dup-factor개 경로에 동일 패킷 순환
```

**aggregate 가중치 분배 알고리즘** (`mud_send_next`, mud_lite.c):
```c
// 매 패킷 전송 시:
for each RUNNING path:
    path->agg_credit += path->tx.rate;  // 속도 비례 크레딧 적립

// 크레딧 최대 경로 선택 (dup_count개):
best->agg_credit -= total_rate;  // 차감으로 다음 기회 균등화

// 결과: 100Mbps 경로는 50Mbps 경로의 2배 패킷 처리
```

### 서버 전용

| 옵션 | 값 범위 | 기본값 | 설명 |
|------|---------|--------|------|
| `--wg ip:port` | — | 필수 | WireGuard upstream 주소 (예: 127.0.0.1:51820) |
| `--decoy ip:port` | — | 없음 | GFW 액티브 프로빙 대응. 지정 시 HMAC 실패 패킷을 로컬 nginx/caddy QUIC 서버로 포워딩. **미지정 시 내장 QUIC Server Initial 1200B로 자동 응답** (nginx 불필요). |
| `--accept-local ip` | IP (포트 불가), 최대 **16개** | 없음 (전부 수락) | **도착한 로컬 주소**가 목록에 있는 패킷만 서비스. 반복 지정. **`-l 0.0.0.0` 일 때만 의미 있다** — 고정 IP 바인딩은 커널이 이미 제한하므로 불일치 항목은 기동 거부. 미일치 패킷은 **조용히 폐기**(응답하면 서비스 안 하는 주소를 광고하게 된다). §27 |

### 릴레이 전용

| 옵션 | 값 범위 | 기본값 | 설명 |
|------|---------|--------|------|
| `--upstream ip:port` | — | — | 단일 upstream 서버 주소 (단일 모드 필수) |
| `--upstream-local ip` | IP (포트 불가) | 없음 | upstream(릴레이→서버) 소켓의 **소스 IP** 고정. 미지정 시 커널이 라우팅 preferred source 를 고른다. **`-l` 리슨 주소는 여기 상속되지 않는다** — 별개 소켓이다(§26). 한 호스트의 릴레이 인스턴스들을 upstream 에서 소스 IP 로 구분해야 할 때 쓴다 |
| `--route "key ip:port"` | — | — | 키별 upstream 라우팅. 반복 가능. `--upstream` 대신 사용. |
| `--decoy ip:port` | — | 없음 | GFW 액티브 프로빙 대응. 서버와 동일 동작. HMAC 실패 패킷을 decoy로 포워딩. |

`--upstream`과 `--route`는 둘 중 하나 이상 필수. 혼용 불가.

**동작 모드 결정**:
- `--route` 없음 + `--upstream` 있음 → 단일 upstream 모드 (`-k` 지정 시 HMAC 검증)
- `--route` 하나 이상 → 키별 라우팅 모드 (HMAC 검증 자동 활성화, `-k` 무시)

### FEC 옵션

| 옵션 | 값 범위 | 기본값 | 설명 |
|------|---------|--------|------|
| `-f x:y` | `x`≥1, `y`≥0 | `20:10` | FEC 비율. x=데이터, y=복구 패킷 수. 예: `10:3` |
| `--fec-timeout N` | `0`–∞ (ms) | `8` | FEC 그룹 flush 대기. 내부: N×1000 µs |
| `--mode 0\|1\|2` | `0` \| `1` \| `2` | `0` | FEC 모드. 0=bandwidth-saving(큐 기반), 1=low-latency(RS), 2=RNLC(Random Linear Network Coding). 클라이언트/서버 동일 설정 필수 |
| `--mtu N` | `100`–`1500` (bytes) | `1250` | FEC 패킷 MTU. WG MTU 1300 기준 1250 권장 |
| `-q N` / `--queue-len N` | `1`–`10000` | `200` | FEC 인코드 큐 길이 (mode 0에만 적용) |
| `--decode-buf N` | `300`–`20000` | `2000` | FEC 디코더 링버퍼 (패킷 수). **연결당** 할당 — 엔트리 3,828 B → 연결당 `2.2 MB + N×3.8 KB` (2000이면 9.4 MB/연결). v1.0.9에서 6000→2000 |
| `--disable-fec` | — | 비활성 | FEC 완전 비활성화 (passthrough) |

**`--decode-buf` 산정** — 링은 시간이 아니라 **패킷 개수**로 축출한다(`fec_manager.cpp` 끝의
`index++; if (index == fec_buff_num) index = 0;` — 시간 기반 만료 없음). 그래서 RTT 는 무관하고,
한 그룹의 패킷이 도착하는 **시간 폭**만 문제가 된다.

```
필요 N  =  (--fec-timeout + 경로 지연차 + 지터폭) × 디코더 도착 pps × 안전계수
링 한 바퀴 = N ÷ 디코더 pps       (디코더 pps = 앱 pps × FEC 증폭, dedup 이후)
```

단일 스레드 상한(15.9 Mbps ≈ 2,150 pps)에서 지연차+지터가 300ms 여도 필요 N ≈ 650 이다.
**N=2000 이면 이 상한 전 구간을 3배 여유로 덮는다.** 그 이상은 연결당 메모리만 쓴다.
연결당 비용 = `2.2 MB + N × 3,828 B` (실측: 2000→9.4 MB, 8000→31.7 MB).

**FEC x:y 내부 파라미터**: 그룹 크기 1~x에 대해 복구 비율 y 적용.
예: `10:3` → 데이터 1~10패킷 + 복구 3패킷/그룹.

**mode 1은 원본을 즉시 보낸다 — 그룹이 차기를 기다리지 않는다.**
`fec_manager.cpp`의 `encode_fast_send`가 상수 1이라, `input()`의 else 분기가 매 패킷마다
`output_n=1`로 그 패킷을 곧바로 내보낸다(systematic, 헤더 `data_num=0`). 그룹이 닫힐 때
(`counter == x` 또는 `--fec-timeout` 만료) 나가는 것은 **아직 안 보낸 마지막 데이터 1개 +
패리티**뿐이다. `about_to_fec` 분기가 데이터로 `actual_data_num - 1` 하나만 내보내는 것이
그 증거다 — 앞선 x−1개가 버퍼에 있었다면 통째로 유실된다.

| | mode 0 | mode 1 |
|---|---|---|
| 원본 편도 지연 | **최대 `--fec-timeout`** (blob에 모아 shard로 분할) | **0** |
| `--fec-timeout`이 늘리는 것 | 전 패킷 지연 | **손실분 복구 지연만** |

실측이 뒷받침한다: `--fec-timeout` 5→10에서 유휴 RTT **+0.75ms**. 원본이 버퍼링된다면
유휴(g=1, 항상 타이머 flush)에서 정확히 +5ms가 나와야 한다.
따라서 mode 1에서 `--fec-timeout` 상향의 대가는 "모든 패킷이 느려짐"이 아니라
**"잃은 패킷의 복구가 늦어짐"** 이다.

**`-f`는 쉼표로 다중 쌍을 줄 수 있다** — `-f 5:1,20:4` 처럼. 문서화돼 있지 않았지만
`rs_from_str`이 원래 지원하는 문법이고, **단일 쌍만 쓰면 저레이트에서 오버헤드가 폭증한다.**

첫 쌍은 `fec_manager.h`의 "special treatment for first parameter"에 의해 **y가 그룹 크기
1..x 전 구간에 평탄하게 펼쳐진다.** 즉 `-f 20:5`는 "그룹 20개에 패리티 5개"가 아니라
**"그룹이 몇 개든 패리티 5개"** 다. 그룹 크기는 트래픽이 정한다:

```
g = 1 + floor(pps × fec-timeout)        (fec_manager.cpp — one-shot 타이머가 그룹 첫 패킷에서 무장)
```

`--fec-timeout 5`에서 g=20에 도달하려면 **3,800 pps**(1200B 기준 단방향 36.5 Mbps)가 필요하다.
운영 레이트는 대개 그 아래라 g는 1~2에 머물고 y를 그대로 지불한다.
**실측: `-f 20:5` 유휴 오버헤드 6.54배.** `-f 5:1,20:4` + `--fec-timeout 10`으로 1.33배.

다중 쌍의 보간 결과는 손으로 유도하면 정수 절단 때문에 틀린다. `5:1,20:4`의 실제 테이블:

| 그룹 크기 g | 1–5 | 6–10 | 11–15 | 16–20 |
|---|---|---|---|---|
| 패리티 y | 1 | 2 | 3 | 4 |

`x`는 **그룹 최대 크기**다(`counter == get_tail().x`에서 flush). `-f 2:1`처럼 x를 작게 두면
고레이트에서도 그룹이 2로 묶여 오버헤드가 50%에 고착된다. tail의 `20:y`는 트래픽이 많을 때
오버헤드를 회복시키는 장치이며 저레이트에서는 발동하지 않아 비용이 0이다.

**⚠️ 회선 사용량은 부하에 단조증가하지 않는다 (톱니).** `g`가 계단이고 패리티 테이블도
계단이라, `g`가 패리티 경계를 넘는 순간 오버헤드가 튄다. 실측 증폭(앱 총량 대비,
duplicate 2경로, `5:1,20:4`/t10):

| 앱 각 방향 | 2 Mbps | 4 Mbps | 6 Mbps | 8 Mbps |
|---|---|---|---|---|
| g | 3 | 5 | 7 | 9 |
| 패리티 y | 1 | 1 | 2 | 2 |
| 증폭 | 3.02× | **2.66×** ← 최적점 | 2.84× | 2.67× |

**레이트가 경계 바로 위에 걸리면 회선을 10~13% 더 먹는다.** 튜닝 시 목표 레이트가 경계의
어느 쪽인지 확인할 것. → `test-results/2026-08-02-50mbps-soak/REPORT.md` §2-1

### 시뮬레이션/디버그 옵션

| 옵션 | 값 범위 | 기본값 | 설명 |
|------|---------|--------|------|
| `-j N` / `--jitter N` | `0`–`10000` ms 또는 `min:max` | `0` | 인공 지터. 내부: µs 단위 저장 (×1000) |
| `--random-drop N` | `0`–`10000` | `0` | 패킷 손실 시뮬. N/10000 확률. 예: 1000=10% |
| `--disable-checksum` | — | 비활성 | 패킷 체크섬 비활성화 |

---

## mud_lite 내부 수치 레퍼런스

### main.cpp에서 설정하는 mud 파라미터

| 파라미터 | 값 | 비고 |
|----------|-----|------|
| `keepalive` | `5,000,000 µs` (5초) | 경로 유지 probe 주기 |
| `timetolerance` | `30,000,000 µs` (30초) | 패킷 시각 오차 허용 범위. 초과 시 조용한 드롭. HMAC ±1슬롯(±30초) 허용범위와 일치시켜 "HMAC 통과 패킷은 mud도 수용" 보장 |
| `beat` (경로당) | `80,000–120,000 µs` (80–120ms 랜덤) | probe 전송 주기. `mud_random_beat()` 경로 포인터+시각 기반 난수. |
| `loss_limit` (경로당) | `200` | LOSSY 임계. `tx.loss > 200` → LOSSY |

### mud_lite.c 내부 상수 및 계산식

| 항목 | 값 | 설명 |
|------|-----|------|
| `MUD_ONE_MSEC` | `1,000 µs` | mud 시간 단위 |
| `MUD_ONE_SEC` | `1,000,000 µs` | — |
| 초기 path rate | `10,000,000 B/s` (10 MB/s) | `tx_max_rate` 미설정 시 |
| rate floor (branch 1) | `1,000,000 B/s` (1 MB/s) | 저트래픽 구간 rate 최솟값 |
| rate ceiling | `125,000,000 B/s` (1 Gbps) | `tx_max_rate` 미설정 시 상한 |
| window floor | `524,288 bytes` (512 KB) | `rate × 100ms < 512KB`이면 512KB 사용 |
| window 갱신 주기 | 경과시간 `≥ 1ms` 시 | `mud_update_window()` |
| `tx.loss` 갱신 주기 | `rx_dt ≥ 1s` 시 (branch 1) | probe 100ms 간격이면 ~1초마다 재계산 |
| `tx.loss` 공식 | `(tx_acc - rx_acc) × 255 / tx_acc` | 0–255 범위 |
| LOSSY 임계 손실률 | `> 200/255 = 78.4%` | `loss_limit=200` 기준 |
| LOSSY → RUNNING 복구 | `tx.loss ≤ loss_limit` 확인 후 즉시 | 다음 `mud_update_path()` (100ms) |
| `MUD_DEDUP_SIZE` | `128` entries | 중복 제거 링버퍼 크기 |
| `MUD_DEDUP_TTL` | `500,000 µs` (500ms) | 중복 패킷 판정 유효시간 |
| `MUD_PATH_MAX` | **`32`** | 최대 경로 수. **동시 피어 상한이기도 하다** — 경로 식별자가 `(local, remote_ip, remote_port)` 라 클라이언트 1개가 슬롯 1개를 쓴다. 33번째부터 `mud_get_path()` NULL → `mud_recv()` 0 → 폐기(v1.3.0 부터 경고 로그). 슬롯은 5분 무수신 시 회수된다(`mud_path_update()`) — 누적 누수가 아니라 **동시** 상한이다. ⚠️ 릴레이 `RELAY_SESSION_MAX` 800 · 서버 `SESSION_MAX` 800 과 25배 어긋난다 |

### mf_client.cpp pending queue

| 항목 | 값 | 설명 |
|------|-----|------|
| `PENDING_Q_CAP` | `512` entries | mud EAGAIN 시 버퍼 크기 |
| 총 버퍼 용량 | `~737 KB` | 512 × (8 + ~1450) B |
| flush 주기 | `100ms` | `mud_update_cb` 호출 주기 |

### obfs 내부 수치

| 항목 | 값 | 설명 |
|------|-----|------|
| QUIC 헤더 크기 | `10 bytes` | flags(1) + HMAC(8) + pad_len(1) |
| TLS 헤더 크기 | `14 bytes` | 0x17(1) + 0x03 0x03(2) + len(2) + HMAC(8) + pad_len(1) |
| HMAC 슬롯 길이 | `30초` | `time(NULL) / 30` |
| HMAC 허용 오차 | `±1 슬롯` (±30초) | 시계 오차 대응 |
| 패딩 버킷 | `{300, 500, 700, 900, 1100, 1300, 1400, 1500}` bytes | 패킷 크기 정규화. 1500B 초과 시 상한 클램프. |
| HMAC 실패 응답 (기본) | QUIC Server Initial **1200~1455B** | `probe_respond_builtin()`: 1200B 기반 + 0~255B 랜덤 추가 |
| HMAC 실패 응답 (decoy) | raw 패킷 → decoy UDP 소켓 전달 | `--decoy` 지정 시. decoy 응답을 프로버에게 중계 |

---

## 빌드 방법

```bash
make -j$(nproc)        # 동적 링크 빌드 → ./multi-fec        (~279 KB)
make static            # 정적 링크 빌드 → ./multi-fec-static  (~1.5 MB)
make static-strip      # 배포용 정적 빌드 → ./multi-fec-dist  (~1.3 MB, 심볼 제거)
make asan              # ASAN+UBSAN 빌드 → ./multi-fec-asan   (진단용, 배포 금지)
make clean             # 클린
```

의존성: gcc/g++ (C11/C++11), libev (bundled in `libev/`), librt, libpthread

### 빌드 타겟 비교

| 타겟 | 결과물 | 크기 | 용도 |
|------|--------|------|------|
| `make` | `multi-fec` | 279 KB | 개발/테스트 |
| `make static` | `multi-fec-static` | 1.5 MB | 정적 빌드 (심볼 포함) |
| `make static-strip` | `multi-fec-dist` | 1.3 MB | 배포용 (권장) |
| `make asan` | `multi-fec-asan` | 16 MB | 메모리/UB 진단 (ASAN+UBSAN) |

### GLIBC 버전 불일치 오류 대응

```
./multi-fec: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
```

빌드 환경(Ubuntu 24.04, GLIBC 2.38)이 실행 환경(Ubuntu 22.04, GLIBC 2.35)보다
높을 때 발생. `make static-strip`으로 해결하는 것이 권장.

```bash
make static-strip
scp multi-fec-dist user@서버:/usr/local/bin/multi-fec
```

---

## 주요 전역 변수 (main.cpp)

| 변수 | 타입 | 용도 |
|------|------|------|
| `g_session_id` | `uint8_t[8]` | 클라이언트 세션 식별자 |
| `g_paths` | `vector<PathSpec>` | --path 목록 |
| `g_wg_addr` | `address_t` | --wg WireGuard 주소 |
| `g_multipath_mode` | `multipath_mode_t` | failover/duplicate/aggregate/aggregate-duplicate |
| `g_dup_factor` | `unsigned` | aggregate-duplicate 경로 중복 수 (기본 2) |
| `g_key_string` | `char[1000]` | PSK 문자열 |
| `g_key_set` | `bool` | -k 명시 여부 (릴레이 HMAC 판단) |
| `g_obfs_mode` | `obfs_mode_t` | QUIC/TLS 위장 모드 |
| `g_decoy_addr` | `address_t` | --decoy 주소 (서버/릴레이 모드) |
| `g_upstream_addr` | `address_t` | 릴레이 --upstream 주소 |
| `g_routes` | `vector<route_entry_t>` | 릴레이 키별 upstream 라우팅 테이블 |

---

## systemd 서비스

환경변수 파일(`/etc/multi-fec/*.conf`)과 서비스 파일을 분리해 관리한다.

### 서버 (`/etc/systemd/system/multi-fec-server.service`)

```ini
[Unit]
Description=multi-fec server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/server.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -s \
    -l ${LISTEN} --wg ${WG} -k ${KEY} \
    --obfs-mode ${OBFS_MODE} -f ${FEC} \
    --mode ${FEC_MODE} --fec-timeout ${FEC_TIMEOUT} \
    --report ${REPORT} --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/server.fifo \
    ${DECOY:+--decoy ${DECOY}}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 클라이언트 (`/etc/systemd/system/multi-fec-client.service`)

```ini
[Unit]
Description=multi-fec client
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/client.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -c \
    -l ${LISTEN} \
    --path 0.0.0.0:SERVER_IP:443 \
    -k ${KEY} --obfs-mode ${OBFS_MODE} \
    --multipath-mode ${MULTIPATH_MODE} \
    -f ${FEC} --mode ${FEC_MODE} --fec-timeout ${FEC_TIMEOUT} \
    --report ${REPORT} --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/client.fifo
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 릴레이 — 단일 upstream (`/etc/systemd/system/multi-fec-relay.service`)

```ini
[Unit]
Description=multi-fec relay/POP
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/relay.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -r \
    -l ${LISTEN} --upstream ${UPSTREAM} \
    -k ${KEY} --obfs-mode ${OBFS_MODE} \
    --auth-interval ${AUTH_INTERVAL} \
    --log-level ${LOG_LEVEL} \
    ${DECOY:+--decoy ${DECOY}}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

### 릴레이 — 키별 upstream 라우팅 (`/etc/systemd/system/multi-fec-relay.service`)

여러 서버로 분기할 때. `-k`/`--upstream` 대신 `--route` 반복 사용.

```ini
[Unit]
Description=multi-fec relay/POP (key-routing)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/relay.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -r \
    -l ${LISTEN} \
    --route "${KEY_A} ${UPSTREAM_A}" \
    --route "${KEY_B} ${UPSTREAM_B}" \
    --auth-interval ${AUTH_INTERVAL} \
    --log-level ${LOG_LEVEL} \
    ${DECOY:+--decoy ${DECOY}}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

`/etc/multi-fec/relay.conf` 예시 (키별 라우팅 + decoy):
```bash
LISTEN=0.0.0.0:443
KEY_A=keyA
UPSTREAM_A=1.2.3.4:443
KEY_B=keyB
UPSTREAM_B=5.6.7.8:443
AUTH_INTERVAL=60       # ★ 클라이언트/서버와 반드시 동일. 불일치 시 모든 패킷이 probe로 폐기됨
DECOY=127.0.0.1:8443   # 미사용 시 이 줄 삭제 → 내장 QUIC Server Initial로 자동 응답
LOG_LEVEL=4
```

> ⚠️ **릴레이 `--auth-interval` 주의**: 릴레이도 HMAC을 검증하므로 `--auth-interval` 값이 클라이언트/서버와 반드시 일치해야 한다(기본 30, 권장 60).
> 불일치 시 HMAC 토큰 슬롯(`time/auth_interval`)이 어긋나 릴레이가 클라이언트 패킷을 GFW probe로 간주해 조용히 폐기한다.
> 증상: 해당 경로 DEGRADED(rx=0), 릴레이에 `[relay] new session` 로그 없음, `ss -unp`에 upstream 소켓 없음.

```bash
systemctl daemon-reload
systemctl enable --now multi-fec-server   # 또는 client / relay
journalctl -u multi-fec-server -f
```

---

## 국제 구간 최적 설정

국제 라인(해저케이블 경유)은 높은 RTT(150~300ms), 패킷 손실(3~10%), 경로별 혼잡이 특징이다.
클라이언트/서버 회선이 각각 1개여도 **릴레이 2개가 서로 다른 해저케이블을 사용하면**
aggregate 모드로 실질적인 처리량 합산이 가능하다.

### 손실률별 FEC 설정

| 링크 상태 | FEC 설정 | 오버헤드 | 커버 손실률 |
|---------|---------|---------|-----------|
| 안정적 (손실 1~3%) | `-f 20:2` | 10% | 최대 9% |
| 일반 (손실 3~8%) | `-f 20:4` | 20% | 최대 16% |
| 불안정 (손실 8~15%) | `-f 20:7` | 35% | 최대 25% |

손실률 모를 때: `-f 20:4`로 시작 후 `--report 30`으로 모니터링하며 조정.

### 클라이언트

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:relay1_ip:443 \
  --path 0.0.0.0:relay2_ip:443 \
  -k STRONGKEY \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode aggregate \
  -f 20:4 \
  --fec-timeout 20 \
  --mode 0 \
  --mtu 1250 \
  --decode-buf 2000 \
  --queue-len 500 \
  --sock-buf 4096 \
  --report 30
```

### 서버

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k STRONGKEY \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode aggregate \
  -f 20:4 \
  --fec-timeout 20 \
  --mode 0 \
  --mtu 1250 \
  --decode-buf 2000 \
  --queue-len 500 \
  --sock-buf 4096 \
  --report 30
```

### 릴레이 (2개 각각)

```bash
multi-fec -r \
  -l 0.0.0.0:443 \
  --upstream server_ip:443 \
  -k STRONGKEY \
  --obfs-mode quic \
  --sock-buf 4096 \
  --log-level 4
```

### WireGuard

```ini
[Interface]
MTU = 1300
```

### 각 설정값 근거

| 옵션 | 값 | 이유 |
|------|-----|------|
| `--fec-timeout 20` | 8→20ms | RTT 200ms 환경에서 8ms는 너무 짧아 그룹 조기 플러시 |
| `--mode 0` | 큐 기반 | 대용량 전송 시 FEC 그룹 효율 극대화. 높은 레이턴시라 큐잉 영향 적음 |
| `--decode-buf 2000` | 기본 6000→2000 | **연결당** 할당이라 다중 클라이언트 서버에서 메모리가 먼저 상한이 된다. 크기 기준은 시간이 아니라 개수다 — 아래 산정식 참고 |
| `--queue-len 500` | 200→500 | 고대역폭 경로에서 FEC 인코더 큐 여유 확보 |
| `--sock-buf 4096` | OS기본→4MB | BDP 500KB 이상 구간에서 커널 버퍼 부족 시 처리량 저하 방지 |
| `--auth-interval 60` | 30→60 | GFW 슬롯 경계 탐지 어렵게 |
| `--multipath-mode aggregate` | — | 두 릴레이의 독립된 해저케이블 대역폭 합산 |

### 인터랙티브 트래픽 (게임·화상통화)

대용량 전송 대신 낮은 지연이 목표일 때:

```bash
--mode 1 \          # 즉시 전송 (큐 없음)
--fec-timeout 5 \   # 빠른 플러시
-f 10:3 \           # 작은 그룹으로 왕복 지연 최소화
--queue-len 100
```

### 2개 릴레이의 처리량 합산 원리

```
클라이언트 (한국) ──path1──▶ Relay1 (홍콩) ──[해저케이블 A]──▶ 서버 (미국)
                  ──path2──▶ Relay2 (도쿄) ──[해저케이블 B]──▶ 서버 (미국)

aggregate 모드 가중 분배:
  케이블 A 실효: 8Mbps
  케이블 B 실효: 12Mbps
  mud_lite가 tx.rate 비례로 B에 60%, A에 40% 분배
  서버 수신 합산: ~20Mbps (단일 경로 12Mbps 대비 67% 향상)

클라이언트/서버 회선이 각 1개여도, 릴레이→서버 경로가 다른 물리 케이블이면 합산 효과 발생.
```

---

## 알려진 제약

- `--path` 경로 추가/삭제, `-k` 키 변경, `--obfs-mode` 변경은 재시작 필요
- `--multipath-mode` / `--dup-factor` 변경은 재시작 필요 (FIFO 런타임 변경 미지원)
- 릴레이에서 HMAC 활성화 시 서버가 패킷을 두 번 decode (릴레이 1회 + 서버 1회)
  — SipHash 연산 비용이 수십 ns 수준이라 실용적 영향 없음
- mud_lite는 단일 UDP 소켓 기반으로 커널 멀티큐 미지원
- WireGuard MTU를 1420으로 두면 IP 단편화 발생 → MTU 1300 권장
- 릴레이 키별 라우팅: 동일 (src_ip, src_port) 세션은 최초 키로 고정, 재협상 없음
- 릴레이 키별 라우팅: `--route` 와 `--upstream`/`-k` 혼용 불가 (시작 시 오류)

---

## 버그 수정 이력

### 1. mud timetolerance / keepalive 단위 오류 (치명적)

**파일**: `main.cpp` — `mud keepalive 설정` 블록

**증상**: 클라이언트가 패킷을 전송하고 서버 tcpdump에도 패킷이 수신되지만,
서버가 아무 응답도 하지 않고 로그도 남지 않음.
`server-->client:(original:0 pkt;0 byte)` 상태가 지속됨.

**원인**: mud의 시간 단위는 **마이크로초** (`MUD_ONE_MSEC = 1000 µs`, `MUD_ONE_SEC = 1,000,000 µs`)인데,
밀리초 값으로 잘못 설정:

```cpp
// 수정 전 (잘못됨)
mconf.keepalive     = 5000;   // 의도: 5초 → 실제: 5ms
mconf.timetolerance = 10000;  // 의도: 10초 → 실제: 10ms
```

`timetolerance = 10ms`이면 `mud_recv()`가 패킷 전송 시각과 수신 시각 차이가 10ms 초과 시
**0을 반환** (로그 없음, 조용한 드롭). WAN 편도 지연이 10ms 이상이면 모든 패킷 드롭.

`mud_lite.c` 기본값:
```c
mud->conf.keepalive     = 25 * MUD_ONE_SEC;  // 25초
mud->conf.timetolerance = 10 * MUD_ONE_SEC;  // 10초
```

**수정 후**:
```cpp
mconf.keepalive     = 5000000ULL;   /* 5초 (5,000,000 µs) */
mconf.timetolerance = 30000000ULL;  /* 30초 — HMAC ±30s 허용범위와 일치, 시계 오차 대응 */
```

> 비고: 초기 수정은 `timetolerance = 0`(→ mud_create 기본값 10초 유지)이었으나,
> 이후 obfs HMAC의 ±1슬롯(±30초) 허용범위와 정합성을 맞추기 위해 30초로 상향했다.
> HMAC을 통과한 패킷(±30s)이 시계 오차로 mud에서 조용히 드롭되는 모순을 제거한다.

**진단 팁**: `timetolerance` 실패는 `mud_recv()` 내부에서 `return 0`으로 처리되어
상위 코드(`mud_io_cb`)의 `n==0` 분기를 탐. 로그가 전혀 남지 않아 진단이 어려움.
`--log-level 5` (trace) 설정 시 `[server] mud_recv=0 from X` 메시지로 확인 가능.

---

### 2. 경로 로그 표시 오류 (표시 버그, 기능 정상)

**파일**: `main.cpp` — `OPT_PATH` 처리, `setup_static_paths()`

**증상**: 시작 로그에 `local=192.168.100.141:0 remote=192.168.100.141:0`처럼
remote가 local과 동일하게 출력됨.

**원인**: `address_t::get_str()`이 정적(static) 버퍼를 사용하므로
같은 `mylog()` 호출에서 두 번 호출 시 두 번째 호출이 버퍼를 덮어씀.
실제 PathSpec 데이터는 정상 — tcpdump로 실제 목적지가 올바름을 확인.

---

### 3. systemd 서비스 파일 주의사항

**줄 연속 문자 뒤 공백 금지**:
```ini
# 잘못됨 — 백슬래시 뒤 공백
    --wg ${WG} \ 
# 올바름
    --wg ${WG} \
```

**ExecStartPre 순서**: systemd는 파일 내 위치와 무관하게 ExecStartPre를 ExecStart 전에 실행하지만,
가독성을 위해 ExecStart 앞에 배치 권장.

**느린 재시작 원인**:
- `After=network-online.target` → `After=network.target`으로 변경
- SIGTERM 핸들러 없음 → 기본 TimeoutStopSec 90초 대기 후 SIGKILL
- 해결: 서비스 파일에 `TimeoutStopSec=3` 추가

---

### 4. mud window 고갈 → 7분 트래픽 블랙아웃 (치명적)

**파일**: `mud_lite.c` — `mud_update_rl()`, `mud_update_window()`

**증상**: ping RTT가 3000~15000ms로 급등 후 ~1024ms/패킷씩 감소하는 패턴.
서버 로그에서 약 7분간 `original:0 pkt` 구간 반복.

**원인 1 — rate branch 1에서 0으로 수렴**:
```c
// branch 1 (rx_dt >= 1s): 측정 throughput으로 rate 재설정
path->tx.rate = 7/8 × rx_bytes / rx_dt
// ping 트래픽처럼 낮은 구간에서 rate → ~35 B/s
// window_max = rate × 100ms ≈ 3.5 bytes → 항상 EAGAIN
```

**원인 2 — window floor 없음**:
window_max가 packet size(~1440B)보다 작아지면 모든 `mud_send()` EAGAIN.
pending queue(당시 64개)가 가득 차면 이후 패킷 실제 드롭 → TCP 재전송 폭증.

**RTT 패턴 해석**: ping 1초 간격으로 64개 패킷이 pending queue에 누적.
window 회복 시 한꺼번에 플러시 → 각 패킷의 대기 시간이 64s, 63s, ... 1s → RTT가 1024ms씩 감소.

**수정 (mud_lite.c)**:
```c
// Fix 1: 초기 rate 10MB/s (기존 100KB/s)
path->tx.rate = tx_max_rate ? tx_max_rate : 10,000,000ULL;

// Fix 2: branch 1 rate 최솟값 1MB/s
uint64_t measured = (7 * rx_bytes * MUD_ONE_SEC) / (8 * rx_dt);
path->tx.rate = measured > 1000000ULL ? measured : 1000000ULL;

// Fix 3: window floor 512KB
uint64_t window_max = mud->rate * 100 * MUD_ONE_MSEC / MUD_ONE_SEC;
if (window_max < 524288) window_max = 524288;
```

**수정 (mf_client.cpp)**:
```c
// pending queue 64 → 512 entries (737KB 버퍼)
#define PENDING_Q_CAP 512
```

---

### 5. tx.loss 고정 → LOSSY 영구 탈출 불가 (치명적)

**파일**: `mud_lite.c` — `mud_update_rl()`

**증상**: 경로 손실이 회복돼도 LOSSY 상태에서 수분~무기한 탈출 불가.
path[1] Starlink가 22% 손실(회복)임에도 계속 LOSSY 유지.

**원인**: `path->msg.rx.time = now`가 branch 밖에서 무조건 실행됨.
probe beat=100ms → rx_dt 항상 ~100ms < 1s → branch 1 미실행 → `tx.loss` 갱신 안 됨.
```c
// 수정 전 (잘못됨)
} // end if/else
path->msg.rx.time = now;  // 무조건 실행 → branch 1 영원히 차단
```

한번 LOSSY 임계(tx.loss > loss_limit) 돌파 후 probe 재개되면 tx.loss가 고점에 고정.

**수정**:
```c
// branch 1 안으로 이동 → 1초마다 tx.loss 재계산
if (rx_dt >= MUD_ONE_SEC) {
    ...
    path->tx.loss = (tx_acc - rx_acc) * 255U / tx_acc;
    ...
    path->msg.rx.time = now;  // ← 이동
}
// path->msg.rx.time = now;  ← 삭제
```

**LOSSY 복구 시간**: 수정 후, 손실 < 78.4%이면 다음 branch 1 실행(~1초) 후 RUNNING 복귀.

---

### 6. 서버 duplicate 모드 미동작 (기능 버그)

**파일**: `mf_server.cpp` — `wg_remote_cb()` FEC 출력 루프

**증상**: `--multipath-mode duplicate` 설정 시 서버→클라이언트 방향이 단일 경로(failover)로만 전송.

**원인**: 서버 FEC 출력 루프에서 `mud_send()` 고정 사용.
```cpp
// 수정 전
mud_send(g_mud, out_arr[i], out_len[i]);
```

**수정** (현재는 `mud_send_mp()` 헬퍼로 통합):
```cpp
// mf_client.cpp / mf_server.cpp 공통 헬퍼
static inline int mud_send_mp(struct mud *mud, const void *data, size_t size)
{
    switch (g_multipath_mode) {
    case MULTIPATH_DUPLICATE:           return mud_send_all(mud, data, size);
    case MULTIPATH_AGGREGATE:           return mud_send_next(mud, data, size, 1);
    case MULTIPATH_AGGREGATE_DUPLICATE: return mud_send_next(mud, data, size, g_dup_factor);
    default:                            return mud_send(mud, data, size);
    }
}
// 모든 mud_send 호출 지점에서 mud_send_mp() 사용
int ret2 = mud_send_mp(g_mud, out_arr[i], out_len[i]);
```

---

### 7. GFW 액티브 프로빙 대응 — decoy 구현

**파일**: `mf_server.cpp`

**배경**: GFW는 의심 IP에 직접 UDP 패킷을 보내 응답을 관찰하는 액티브 프로빙을 사용한다.
기존 TLS close_notify 응답은 UDP 위에서 비표준이라 탐지 가능성 있음.

**구현**: `--decoy ip:port` 옵션 추가. HMAC 인증 실패 패킷을 로컬 nginx/caddy QUIC 서버로
포워딩하고 그 응답을 프로버에게 중계. 프로버 주소마다 독립 UDP 소켓 생성.
`--decoy` 미지정 시에는 내장 QUIC Server Initial로 응답 (§11 참고).

적용 범위:
- `mud_io_cb`: n<0(포맷 오류), n==0 auth-fail 케이스
- `server_totp_io_cb`: n<=0 케이스 (TOTP 포트로 수신된 프로브)

```bash
# 사용 예
multi-fec -s -l 0.0.0.0:443 --wg 127.0.0.1:51820 -k KEY --decoy 127.0.0.1:8443
# nginx는 TCP :443 + UDP :8443 에서 QUIC 서비스
```

포트 역할:
| 포트 | 프로토콜 | 바인딩 | 역할 |
|------|---------|--------|------|
| `:443` UDP | multi-fec | 외부 | 정상 클라이언트 + 프로브 수신 |
| `:443` TCP | nginx | 외부 | GFW TCP 프로브 직접 처리 |
| `:8443` UDP | nginx QUIC | 루프백 | decoy 응답 생성 (외부 비노출) |

---

### 8. 클라이언트 멀티패스 — policy routing 필수

두 physical interface가 다른 서브넷(예: 192.168.100.x, 192.168.1.x)이면,
기본 라우팅 테이블은 단일 default route를 사용하므로 두 번째 소스 IP의 패킷이
잘못된 인터페이스로 나간다.

```bash
# 확인
ip route get <서버IP> from <소스IP1>
ip route get <서버IP> from <소스IP2>
# 각각 다른 dev가 나와야 정상

# 수정 (policy routing)
ip route add default via <GW1> dev <IF1> table 101
ip route add default via <GW2> dev <IF2> table 102
ip rule add from <소스IP1> table 101 priority 100
ip rule add from <소스IP2> table 102 priority 101
```

영구 적용은 별도 systemd 서비스(`policy-routing.service`)로 관리 권장.

---

### 9. 릴레이 키별 upstream 라우팅 구현

**파일**: `mf_relay.cpp`, `main.cpp`, `mf_common.h`

**배경**: 단일 POP에서 여러 서버(팀/조직별 분리, 지역별 분기 등)로 클라이언트를 라우팅하려면
각 연결마다 다른 upstream을 지정해야 한다. 기존 단일 `--upstream` 옵션으로는 불가능.

**구현**:
```cpp
// mf_common.h
struct route_entry_t {
    char            key_str[1000];
    address_t       upstream_addr;
    struct obfs_ctx obfs;          // 키별 독립 HMAC 컨텍스트
};
extern std::vector<route_entry_t> g_routes;

// 라우팅 결정: 신규 세션의 첫 패킷에서 HMAC 순서 매칭
for (const route_entry_t &route : g_routes) {
    int plen = obfs_decode(&route.obfs, buf, n, decoded, ...);
    if (plen > 0 || plen == OBFS_DECODE_INITIAL)
        → upstream = route.upstream_addr  // 첫 성공 route 사용
}
// 모두 실패 → decoy 또는 close_notify
```

세션 생성 후 `relay_session_t::route_obfs`에 매칭된 obfs 컨텍스트 저장.
이후 동일 (src_ip, src_port)의 모든 패킷은 저장된 obfs로만 재검증.

**테스트**: `test_relay_routing.py` — 7/7 케이스 통과 (2026-06-03)
- keyA → upstream A 라우팅
- keyB → upstream B 라우팅 (별도 소켓 필요 — 세션 고정 동작 확인)
- 잘못된 키 → QUIC Server Initial 1200B (decoy 미설정)
- raw 패킷 → QUIC Server Initial 1200B (decoy 미설정)
- 기존 세션 연속 10패킷

---

### 10. 릴레이 decoy 지원 추가

**파일**: `mf_relay.cpp`, `main.cpp`

**배경**: 릴레이도 외부 포트(:443)를 리슨하므로 GFW 액티브 프로빙 대상이 된다.
기존에는 HMAC 실패 시 close_notify만 응답했는데, 서버와 달리 decoy가 없어 핑거프린팅 가능.
(현재는 §11의 내장 QUIC Initial이 기본 동작으로 적용됨)

**구현**: 서버의 decoy 로직(`decoy_sess_t`, `decoy_io_cb`, `decoy_get_or_create`,
`decoy_forward`, `decoy_cleanup_cb`)을 릴레이에 이식.
차이점: 릴레이는 단일 `g_listen_fd`를 사용하므로 `decoy_sess_t`에 `listen_fd` 필드 불필요.

HMAC 실패 3개 경로 모두 분기 처리:
```cpp
if (g_decoy_enabled)
    decoy_forward(src, buf, n);
else
    probe_respond_builtin(src);   /* → 내장 QUIC Server Initial */
```

`--decoy` 옵션이 서버/릴레이 양쪽에서 동작. help 텍스트 `[Server]` → `[Server/Relay]`.

```bash
# 사용 예
multi-fec -r -l 0.0.0.0:443 \
    --route "keyA server_ip:443" \
    --decoy 127.0.0.1:8443
```

---

### 11. 내장 QUIC Server Initial 응답 (nginx 불필요)

**파일**: `mf_server.cpp`, `mf_relay.cpp`

**배경**: 기존 TLS close_notify(7B)는 UDP 위에서 비표준이라 GFW 핑거프린팅에 취약.
`--decoy`는 nginx/caddy가 필요해 운영 부담이 있음.

**구현**: `probe_respond_tls_close_notify` → `probe_respond_builtin`으로 교체.
기존 `obfs_encode_initial(ctx, buf, 1200, is_server=1)`을 재활용해 RFC 9000 준수
QUIC Long Header Initial 1200B를 직접 생성·전송.

```cpp
static void probe_respond_builtin(int fd, address_t &src)  /* server */
{
    static char buf[QUIC_INITIAL_SIZE + 256];
    int n = obfs_encode_initial(g_obfs, buf, sizeof(buf), 1);
    if (n <= 0) return;
    int extra = rand() % 256;   /* 0~255B 랜덤: QUIC coalesced packet 영역 */
    for (int i = n; i < n + extra; i++) buf[i] = (char)(rand() & 0xFF);
    sendto(fd, buf, (size_t)(n + extra), 0, (struct sockaddr *)&src.inner, src.get_len());
}
```

릴레이는 `g_builtin_ctx`를 `g_obfs` → `g_routes[0].obfs` → 빈 키 순으로 초기화해 사용.
PSK에서 파생된 HMAC 토큰이 DCID에 들어가지만 프로버는 검증할 수 없으므로 무방.

**우선순위 정리**:
```
HMAC 실패
├── --decoy 있음 → 외부 서버(nginx/caddy) 포워딩 + 응답 중계
└── --decoy 없음 → 내장 QUIC Server Initial 1200B  ← 기본값 (nginx 불필요)
```

**응답 패킷 구조**:
```
[0xC1]            QUIC Long Header | Fixed | Initial | PN_len=2
[0x00000001]      QUIC version 1
[0x08]            DCID length = 8
[8B HMAC token]   PSK 기반 토큰 (프로버가 검증 불가)
[0x08]            SCID length = 8
[0xFF ...]        SCID[0]=0xFF → Server Initial 마커
[0x00]            Token length = 0
[0x44 0x96]       payload length varint = 1174
[0x0000]          Packet Number
[0x00 × 1172]     PADDING frames
```

테스트: `test_relay_routing.py` TC3/TC4 — ≥1200B QUIC Initial, `0xC1` 헤더, `SCID[0]=0xFF` 확인 (2026-06-03)

---

### 12. GFW 핑거프린팅 대응 강화 (5개 항목)

**파일**: `obfs.h`, `obfs.cpp`, `mf_server.cpp`, `mf_relay.cpp`, `main.cpp`, `mud_lite.c`

**배경**: GFW 탐지 수준 분석(B+ 등급) 후 즉시 적용 가능한 항목 5개를 순차 수정.

#### 12-1. 패딩 버킷 확대 + 상한선 (obfs.h / obfs.cpp)

```c
/* 수정 전 */
#define OBFS_BUCKET_COUNT 6
const int obfs_buckets[] = {300, 500, 700, 900, 1100, 1300};
/* return total_needed;  ← 1300B 초과 시 원본 크기 노출 */

/* 수정 후 */
#define OBFS_BUCKET_COUNT 8
const int obfs_buckets[] = {300, 500, 700, 900, 1100, 1300, 1400, 1500};
/* return obfs_buckets[OBFS_BUCKET_COUNT - 1];  ← 상한 클램프 */
```

WireGuard MTU 1420 등 큰 패킷이 1300B 버킷을 벗어나던 문제 해결.

#### 12-2. QUIC Initial 응답 크기 랜덤화 (mf_server.cpp / mf_relay.cpp)

```cpp
/* 1200B 고정 → 1200~1455B 랜덤 */
int extra = rand() % 256;
for (int i = n; i < n + extra; i++) buf[i] = (char)(rand() & 0xFF);
sendto(fd, buf, n + extra, ...);
```

매번 동일한 1200B 응답으로 탐지되던 패턴 제거.
추가 바이트는 QUIC coalesced packet 영역으로, 수신 측이 파싱 실패 시 무시.

#### 12-3. `--auth-interval` 옵션 추가 (main.cpp)

HMAC 슬롯 길이를 CLI에서 설정 가능. 기본 30초 유지 (하위 호환).
클라이언트/서버 양쪽 동일하게 설정 필수. 권장값: `--auth-interval 60`.

```bash
multi-fec -s -l 0.0.0.0:443 --wg 127.0.0.1:51820 -k KEY --auth-interval 60
multi-fec -c -l 127.0.0.1:51820 --path ... -k KEY --auth-interval 60
```

슬롯이 길어질수록 통계 분석으로 경계 탐지가 어려워지고, 허용 시계 오차(±1슬롯)가 늘어남.

#### 12-4. 설정 경로 beat 랜덤화 (main.cpp)

```cpp
/* 수정 전 */
pc.beat = 100 * 1000;  /* 100ms 고정 */

/* 수정 후 */
pc.beat = (uint64_t)(80 + rand() % 41) * 1000ULL;  /* 80–120ms 랜덤 */
```

경로별로 다른 beat → probe 패킷 IAT(Inter-Arrival Time) 분포 다양화.
`srand(time(NULL))`로 시드 초기화.

#### 12-5. PASSIVE 경로 beat 랜덤화 (mud_lite.c)

```c
/* mud_random_beat(): 경로 포인터 + time(NULL) 기반 xorshift 난수 */
static uint64_t mud_random_beat(const void *path_ptr) {
    uint64_t h = (uint64_t)(uintptr_t)path_ptr ^ (uint64_t)time(NULL);
    h ^= h >> 33; h *= 0xff51afd7ed558ccdULL; ...
    return (uint64_t)(80 + (h % 41)) * 1000ULL;  /* 80–120ms */
}

/* mud_set_path() 및 mud_recv() PASSIVE 경로 생성 시 */
if (!path->conf.beat) path->conf.beat = mud_random_beat(path);
```

서버/클라이언트 모두 beat가 80~120ms 범위로 다양화.
srand 없이 경로 포인터 주소와 시각을 엔트로피 소스로 사용.

---

### 13. 멀티패스 집계 모드 구현 (aggregate / aggregate-duplicate)

**파일**: `mf_common.h`, `mud_lite.h`, `mud_lite.c`, `mf_client.cpp`, `mf_server.cpp`, `main.cpp`

**배경**: 기존 failover/duplicate 모드로는 물리 회선 대역폭 합산이 불가능했음.
aggregate 모드 추가로 복수 ISP 회선의 대역폭을 실제로 합산할 수 있게 됨.

#### 13-1. `mud_send_next()` 가중 라운드로빈 (mud_lite.c)

```c
int mud_send_next(struct mud *mud, const void *data, size_t size, unsigned dup_count)
{
    // 1. 모든 RUNNING 경로에 tx.rate 비례 크레딧 적립
    for each RUNNING path:
        path->agg_credit += path->tx.rate;

    // 2. 크레딧 최대 경로 순으로 dup_count개 선택 후 전송
    for d in 0..dup_count:
        best = argmax(agg_credit, RUNNING & unselected)
        best->agg_credit -= total_rate  // 균등화 (다음 기회 순환)
        mud_send_path(best, packet)

    // 3. window는 논리적 1패킷만 차감
}
```

`mud_path.agg_credit` 필드(int64_t)를 경로 구조체에 추가.
100Mbps 경로는 50Mbps 경로의 2배 패킷 처리 — tx.rate 변화 시 자동 재균형.

#### 13-2. 새 멀티패스 모드 (mf_common.h)

```c
enum multipath_mode_t {
    MULTIPATH_FAILOVER            = 0,  // 기존
    MULTIPATH_DUPLICATE           = 1,  // 기존
    MULTIPATH_AGGREGATE           = 2,  // 신규: 경로 대역폭 합산
    MULTIPATH_AGGREGATE_DUPLICATE = 3,  // 신규: 집계 + 이중화 혼합
};
```

#### 13-3. mud_send_mp() 공통 헬퍼 (mf_client.cpp / mf_server.cpp)

모든 mud_send 호출 지점을 단일 헬퍼로 통합. 모드 추가 시 한 곳만 수정.

```cpp
static inline int mud_send_mp(struct mud *mud, const void *data, size_t size)
{
    switch (g_multipath_mode) {
    case MULTIPATH_DUPLICATE:           return mud_send_all(mud, data, size);
    case MULTIPATH_AGGREGATE:           return mud_send_next(mud, data, size, 1);
    case MULTIPATH_AGGREGATE_DUPLICATE: return mud_send_next(mud, data, size, g_dup_factor);
    default:                            return mud_send(mud, data, size);
    }
}
```

#### 13-4. CLI 옵션 (main.cpp)

```bash
--multipath-mode aggregate           # 순수 집계: 경로 대역폭 합산
--multipath-mode aggregate-duplicate # 집계 + 이중화: dup-factor 경로에 전송
--dup-factor N                       # aggregate-duplicate에서 경로 중복 수 (기본 2, 범위 1-8)
```

#### 사용 예시

```bash
# 두 ISP 완전 집계 (최대 처리량)
multi-fec -c -l 127.0.0.1:51820 \
    --path 192.168.1.x:서버IP:443 \
    --path 10.0.0.x:서버IP:443 \
    --multipath-mode aggregate -f 20:1

# 세 경로: 집계 + 이중화 (처리량 + 안정성 균형)
multi-fec -c -l 127.0.0.1:51820 \
    --path ISP-A:서버IP:443 \
    --path ISP-B:서버IP:443 \
    --path ISP-C:서버IP:443 \
    --multipath-mode aggregate-duplicate --dup-factor 2
# → 각 패킷이 2개 경로에 전송, 3개 경로 중 어느 2개가 살아 있으면 정상 동작
```

---

### 14. srand() 시드 개선 + 전체 옵션 테스트 스크립트

**파일**: `main.cpp`, `test_all_options.py`

#### 14-1. srand() 시드 개선 (main.cpp)

**배경**: `srand(time(NULL))`은 초 단위 해상도라 1초 이내에 재시작하면 동일한 난수 시퀀스가 반복됨.
beat 랜덤화(80~120ms)와 probe 응답 크기 랜덤화(1200~1455B)에 영향.

```cpp
/* 수정 전 */
srand((unsigned)time(NULL));

/* 수정 후: clock_gettime 나노초로 높은 엔트로피 확보 */
struct timespec ts;
clock_gettime(CLOCK_MONOTONIC, &ts);
srand((unsigned)(ts.tv_sec ^ ts.tv_nsec));
```

보안 목적 난수가 아닌 크기 다양화·타이밍 지터용이므로 rand()로 충분.
단, 빠른 재시작 시에도 다른 패턴을 보장.

#### 14-2. 전체 옵션 시뮬레이션 테스트 (`test_all_options.py`)

**90/90 통과** (2026-06-03)

| 카테고리 | 항목 수 | 내용 |
|---------|--------|------|
| CLI 유효성 검사 | 4 | 모드 없음, 알 수 없는 옵션, --version, -h |
| 필수 옵션 누락 | 3 | 클라이언트 --path, 서버 --wg, 릴레이 --upstream |
| 범위 검사 (오류 확인) | 13 | --dup-factor, --auth-interval, --mtu 등 |
| 유효 옵션 파싱 | 54 | 릴레이 10종, 클라이언트 44종 |
| 패킷 전달 기능 | 8 | 투명 포워딩, HMAC 검증, 키별 라우팅, decoy 중계 |
| obfs 프로브 응답 | 4 | quic/tls 모드, QUIC Initial 크기 다양성 |
| auth-interval 슬롯 | 2 | 30초/60초 슬롯 HMAC 검증 |
| FIFO 런타임 커맨드 | 2 | 시작, 커맨드 수신 후 크래시 없음 |

주요 검증 결과:
- QUIC Initial 응답 크기: 매 요청마다 다양 (`1223, 1265, 1346, 1352, 1365, 1367, 1373, 1400`B) ✓
- auth-interval 60초 슬롯: 올바른 슬롯 패킷만 upstream 전달 ✓
- decoy: HMAC 실패 패킷이 decoy 서버에 도달하고 응답이 클라이언트에 중계됨 ✓

---

### 15. 기능별 성능·안정성 테스트 (`test_perf_stability.py`)

**26/26 통과** (2026-06-03)

| 테스트 | 핵심 수치 | 판정 |
|--------|----------|------|
| obfs 인코딩 속도 | 8,416 pkt/s (Python 구현) | ✓ |
| 릴레이 처리량 | 손실 0%, 627 pkt/s | ✓ |
| 키별 분배 정확도 | A=100/100, B=100/100 (100%) | ✓ |
| burst 1,000패킷 안정성 | 손실 0%, 68.5ms | ✓ |
| 다수 클라이언트 동시 연결 | 릴레이 생존 확인 (루프백 한계) | ✓ |
| decoy 세션 타임아웃 | 10초 후 만료, 재생성 정상 | ✓ |
| 패딩 버킷 분포 | 8개 버킷 계산 정확도 100% | ✓ |
| 잘못된 패킷 내성 | 1,009개 비정상 패킷 후 생존 | ✓ |
| 15초 연속 처리 | 손실 0.0% | ✓ |
| HMAC 슬롯 경계 | ±1 수락, ±2 정확히 거부 | ✓ |

---

### 16. RNLC FEC 모드 추가 (`--mode 2`)

**파일**: `rnlc.cpp`, `rnlc.h`, `connection.h`, `misc.cpp`, `mf_client.cpp`, `mf_server.cpp`, `main.cpp`, `fec_manager.h`, `Makefile`

**배경**: 기존 FEC는 Reed-Solomon(`lib/fec`, `lib/rs`)뿐. 선택 가능한 별도 FEC 알고리즘으로
Random Linear Network Coding을 `--mode 2`로 추가. RS와 동일하게 `-f x:y`(x=세대 크기 k, y=코딩 패킷 수 r) 사용.

**설계** (블록 기반 systematic RLNC):
- 한 세대 = 원본 k개 + 코딩 r개(GF(256) 위 원본들의 랜덤 선형결합)
- 원본(systematic) 패킷은 그대로 전송 → 무손실 시 디코드 비용/지연 0
- 디코더는 도착한 임의의 k개(원본+코딩, 1차 독립)를 가우스 소거로 복구
- GF(256)은 `rnlc.cpp` 내부 자체 구현 (primitive poly 0x11d) — upstream `lib/fec` 미수정 원칙 유지

**와이어 포맷** (RS와 동일한 8B 헤더 재사용, `type=2`):
```
[4B seq(generation id)][1B type=2][1B k][1B r][1B inner_index]
- inner_index <  k : systematic 패킷, payload = [2B len][data]      (자연 길이)
- inner_index >= k : 코딩 패킷,       payload = [k 계수][코딩 심볼]  (symbol_len 고정)
```

**통합 방식**:
- `misc.cpp` `from_normal_to_fec`/`from_fec_to_normal`에서 분기.
  인코드: `g_fec_par.mode==2`이면 `rnlc_encode_manager` 사용.
  디코드: 패킷 type 바이트(헤더 offset 4)가 2이거나 `mode==2`이면 `rnlc_decode_manager` 사용.
- `conn_info_t`에 `rnlc_encode_manager` / `rnlc_decode_manager` 추가.
- 대용량 버퍼는 mode==2일 때만 lazy 할당. mode==2에선 RS `fec_decode_manager` 링버퍼 할당을 생략해
  연결당 메모리 중복(약 2×) 제거.

**RS(mode 0/1) 대비 차이**:
- RS는 고정 위치 복호(systematic + parity), RLNC는 계수벡터를 실어 임의 부분집합으로 복구.
- 둘 다 MDS급: k+r 중 임의 k개 도착 시 복구. RLNC는 코딩 패킷마다 k바이트 계수 오버헤드.
- 클라이언트/서버 `--mode` 동일 설정 필수(비대칭 불가).

**테스트** (2026-06-17):
- `test_rnlc_unit` (`make test-rnlc-unit`) — 인코드→임의 드롭→디코드 결정적 복구 검증 11/11 통과.
  GF(256) 역원·분배법칙, 10:5/20:10 최대손실 복구, sys+coded 혼합손실, 손실>r 복구불가 판정 포함.
- `test_rnlc.py` — 실제 client/server 바이너리 end-to-end 통합·무결성·생존 9/9 통과.
- ASAN+UBSAN 스트레스(k=20, 버스트, 가변 크기)에서 RNLC 경로 메모리 오류 0건.
- mode 0/1(RS) e2e 회귀 정상(200/200, corrupt=0).

**제약/향후**: 현재는 블록(generation) 단위. 릴레이 recoding(중간 노드 재부호화)이나 sliding-window는 미구현.

---

### 17. RNLC 코딩 계수 랜덤 → Cauchy(MDS) 교체

**파일**: `rnlc.cpp` — `rnlc_encode_manager_t::input()` 코딩 패킷 계수 생성

**배경**: 10세션 다운스트림 측정(2026-06-19, netem 15%)에서 RNLC(mode2) TCP goodput이
RS(mode1)의 ~1/4(2.93 vs 12.0 Mbps). UDP는 8Mbit/s를 거의 다 통과(7.96)했고 디코드
연산량도 사소(~4.5M byte-op/s)해 **CPU 병목이 아니라 잔여손실(0.68% vs RS 0.006%, 100배)이
TCP를 무너뜨린 것**으로 판명(TCP BW ∝ 1/√loss).

**원인**: 코딩 계수가 순수 난수(`get_fake_random_number() & 0xFF`)라 수신 코딩 패킷들이
1차 종속일 확률(여유분==손실수일 때 ~0.4%)이 있어 손실 ≤ r 인데도 복구 실패. RS(Vandermonde,
MDS)는 임의 k개 수신 시 항상 복구하므로 이 실패가 없음.

**수정**: 계수를 **Cauchy 행렬**로 — `P[j][c] = 1/((k+j) XOR c)` (x_j=k+j 코딩 r행,
y_c=c k열, 범위 분리로 x_j⊕y_c≠0 보장). systematic `[I|P]`에서 P가 Cauchy면 모든 정방
부분행렬 가역 → **MDS** → RS와 동일하게 임의 k개 수신 시 복구 보장. 디코더는 계수를 wire에서
읽어 일반 가우스 소거하므로 **무변경**. 전제 k+r≤255는 기존 r 클램프로 보장.

**검증**: `test_rnlc_unit` 11/11(최대손실 복구가 이제 결정적). 전체 빌드 정상.

**⚠️ 측정 결과 — 처리량 개선은 미검증**: Cauchy 바이너리를 s.xdn/c.xdn에 배포해 mode2
다운스트림 재측정(2026-06-19) 결과 **TCP 2.5~3.0 Mbps로 기존(2.93)과 변화 없음**. 즉
"랜덤계수 rank결핍 잔여손실이 TCP를 무너뜨렸다"는 가설은 **검증 실패**(잔여손실을 고쳐도
TCP가 안 오름). UDP는 고정 1200B에서 0% 손실로 회귀 없음 확인. 본 수정은 **RNLC를 진짜
MDS로 만드는 정합성 개선**으로서 유효하나(불필요한 복구실패 ~0.4% 제거), throughput 격차의
원인은 아니다. 측정 후 운영은 원본 바이너리+mode1로 원복.

**근본원인 — CPU 병목도 데이터로 기각, 지연/재정렬이 유력**: c.xdn(Atom N2600) pidstat 측정
결과 mode1 12.4Mbps@CPU65% vs mode2 3.04Mbps@CPU33%. mode2가 처리량 1/4인데 CPU는 더
낮음(놀고 있음) → **디코드 CPU 병목 아님 확정**. 즉 mode2는 무언가를 기다린다(지연). 단서:
mode2 UDP out-of-order가 mode1의 2배. **유력 결론: RNLC가 코딩 패킷을 세대 내 systematic 뒤에
전송(`rnlc.cpp:186-225`)해 손실분 복구가 지연·순서뒤섞임 → WG 위 TCP가 손실로 오판 → cwnd
collapse → 링크 idle인 채 ~3Mbps 고착**. (fec/original≈2.1x 과다오버헤드는 `-f 20:5`가 모든
세대에 r=5 적용(`fec_manager.h:94-99`)한 것 — mode1/2 공통, 격차원인 아님.) 다음 검증: sv1
WG-루프백+netem으로 재정렬 재현·프로파일(운영 무영향) → 수정방향은 디코드 in-order 전달 또는
복구지연 단축. 가설 정리(①CPU ②rank결핍 ③지연/재정렬): ①②는 실측 기각, ③ 유력.
세부: `test-results/2026-06-19-multi-session/downstream-fec/rnlc-decode-bottleneck-analysis.md`.

---

### 18. 소스 리뷰 지적 8건 검증 후 3건 수정 (2026-07-31, v1.0.1)

리뷰에서 제기된 결함 8건 + 경미 3건을 전부 코드로 검증했다. 사실로 확인되고 자체 코드에 속하는 3건을 수정.
**세 수정 모두 와이어 포맷 무변경** — 교차 조합 16종(신규/수정전/운영배포본 × server/client × failover/duplicate)
실측 전달률 100%로 구버전 양방향 호환 확인.

#### 18-가. mud dedup 오탐으로 정상 패킷 폐기 (치명적, 실측 확정)

**파일**: `mud_lite.c` — `mud_recv()` dedup 블록, `mud_dedup_hash()`/`mud_dedup_index()` 신설

**증상**: 버스트 트래픽에서 원인 불명의 패킷 손실. `--multipath-mode failover`처럼 **복제가 전혀 없는 모드에서도** 발생.

**원인**: dedup 판정 키가 패킷 타임스탬프(`pure_time`) **단독**이었다.
```c
if (mud->dedup[d].pkt_time == pure_time) return 0;   /* 수정 전 */
```
`MUD_TIME_MASK(X) = X & ((1<<48) - 2)`가 bit0을 지우는데, 이건 실수가 아니라 **bit0을 `MUD_MSG`
data/probe 플래그로 쓰는 glorytun 설계**다(`MUD_MSG(X) = X & 1`). 그 대가로 타임스탬프 해상도가 **2µs**가 되고,
FEC 그룹 flush는 `-f 20:5`에서 25개를 연속 `sendto`하므로 서로 다른 패킷이 같은 2µs 버킷에 들어가
**두 번째 이후가 조용히 폐기**됐다. dedup 블록에 모드 게이트도 없어 복제가 원천적으로 없는 모드에서도 실행됐다.

**실측** (계측 빌드, 루프백 단일 경로, `--disable-fec`, failover):
| | 수정 전 | 수정 후 |
|---|---|---|
| dedup 도달 패킷 | 5,841 | 6,000 |
| **dedup 폐기** | **160** | **0** |
| 0.2ms 간격(2.6k pps) 손실 | 1.40% | 0.00% |
| 버스트(20k pps) 손실 | 12.70% | 1.96% (수신기 병목분) |

**수정**: 키를 `(타임스탬프, 페이로드 해시)`로 보강하고, 128엔트리 링버퍼 선형탐색을
**1024엔트리 직접사상**으로 교체(패킷당 128회 비교 제거).
```c
uint64_t hash = mud_dedup_hash(decoded + MUD_TIME_SIZE, decoded_size - MUD_TIME_SIZE);
unsigned idx  = mud_dedup_index(pure_time, hash);
if (slot 유효 && TTL 내 && pkt_time 일치 && hash 일치) return 0;
```
진짜 복제본은 바이트가 동일하니 해시도 같아 정상 제거되고, 서로 다른 패킷은 해시가 달라 충돌하지 않는다.

> **설계 판단**: 리뷰는 "키에 시퀀스 추가"를 처방했지만 그러면 mud 헤더 6바이트가 늘어 **와이어 호환이 깨진다**.
> 페이로드 해시는 수신측만 바뀌어 호환성이 유지되므로 이쪽을 택했다.
> 또 "duplicate 계열에서만 dedup 실행" 게이트는 **넣지 않았다** — 클라이언트/서버가 각자 자기
> `--multipath-mode`로 동작하므로, 클라이언트만 duplicate인 구성에서 서버가 dedup을 꺼버리는 부작용이 생긴다.
>
> **잔존 한계**: 직접사상이라 슬롯이 덮인 복제본은 통과할 수 있다(무해 — FEC 디코더는 같은 그룹 슬롯을
> 재기록하고 WireGuard가 재생을 거부한다). 반대로 **바이트까지 완전히 동일한 서로 다른 패킷**이 같은 2µs에
> 들어오면 여전히 폐기된다. 와이어에 시퀀스가 없는 한 이 둘은 원리적으로 구분 불가이며, 실제 페이로드는
> WireGuard 패킷(고유 카운터 포함)이라 발생하지 않는다. 합성 테스트에서 동일 페이로드를 보내면 재현된다.

#### 18-나. 서버 세션 테이블 무한 증가

**파일**: `mf_server.cpp` — `g_session_to_addr`, `session_sweep()`/`session_insert()`/`session_cleanup_cb()` 신설

**원인**: `unordered_map<uint64_t, address_t> g_session_to_addr`에 `erase`·만료·상한이 **전혀 없었다**.
`session_id`는 클라이언트가 만드는 8바이트이므로 유효 토큰 보유자가 무작위 id를 주입하면 메모리가 무제한 증가하고,
공격이 없어도 클라이언트 재시작마다 죽은 엔트리가 누적됐다. `conn_manager`에는 `max_conn_num = 200` 상한이
있지만 **세션 맵은 그 상한과 무관**하게 자란다.

**수정**: 값 타입을 `session_entry_t{addr, last_seen}`으로 바꿔 5분 유휴 만료(30초 주기 `ev_timer` sweep,
`--decoy` 여부와 무관하게 무조건 등록) + `SESSION_MAX = max_conn_num × 4` 상한과 LRU 축출 추가.

**실제 관측된 영향**: 인증을 통과한 발신자만 엔트리를 만들 수 있고, 운영에서 실제로 문제가 된 것은
클라이언트 재시작마다 죽은 엔트리가 누적되어 해제되지 않는 쪽이었다.

#### 18-다. obfs `pkt_type` 필드 손상

**파일**: `obfs.cpp` — `encode_quic()` / `decode_quic()`

**원인**: `p[0] = 0x40 | (token[0] & 0x3F) | ((pkt_type & 0x03) << 4)` — `0x3F` 마스크가 비트 0–5를 덮는데
`pkt_type`이 비트 4–5를 쓰므로 OR 충돌. 디코더가 `(p[0] >> 4) & 0x03`으로 읽어 토큰 값에 따라 DATA를
PROBE/PAD로 오분류했다. 소비처가 없어 무증상이었다.

**수정**: 와이어 바이트에서 `pkt_type`을 제거하고 디코더는 `OBFS_TYPE_DATA`를 반환(`decode_tls`와 동일).
**구버전 무영향 근거**: 인증에 쓰이는 `token[0]`은 `p[8]`에 원본 그대로 실려 그것만 검증되고(`obfs.cpp` encode/decode),
`p[0]`은 QUIC 판별용 `(p[0] & 0xC0) == 0x40`만 확인되므로 하위 6비트는 장식이다.

#### 18-라. 이번 릴리스에서 다루지 않은 항목

리뷰 지적 중 나머지는 이번 범위에서 제외했다. 사유는 항목별로 ① 사용자가 수정을 거절한 사안,
② `fec_manager.cpp` / `packet.cpp` 등 **upstream(UDPspeeder) 코드**라 "upstream 미수정" 원칙과 충돌,
③ 기본 설정에서 발현되지 않아 설계 판단이 선행되어야 하는 사안으로 나뉜다.

> **이 리포는 공개 저장소다.** 미수정 항목의 위치·조건·재현 방법은 여기에 적지 않는다.
> 상세 목록과 우선순위는 리포 밖 내부 기록(`~/mf-verify/UNFIXED-INTERNAL.md`)에 둔다.

#### 18-마. 리뷰 지적 중 사실과 달랐던 것

- **"dedup 링 크기 128로 상향"** — `MUD_DEDUP_SIZE`는 **이미 128**이었다. 다만 20k pps에서 링이 5.6ms마다
  순환해 의도한 500ms 창이 실효 축소되는 별개 문제가 있었고, 1024 직접사상 교체로 해소.
- **"`MUD_TIME_MASK`의 LSB 제거가 결함"** — bit0은 `MUD_MSG` 플래그다(설계). 처방은 마스크 수정이 아니라 키 보강.
- **"판정 키를 `pkt_time + 시퀀스`로 변경"** — 시퀀스는 와이어 변경이라 호환성이 깨진다. 페이로드 해시로 대체.

---

### 19. 다중 클라이언트 다운스트림 오배송 외 5건 (2026-07-31, v1.0.2)

추가 리뷰 지적 8건을 전부 코드로 검증했다. 리뷰가 "높음"으로 올린 항목들은 실제로는 종료 시 1회 회수 또는
현재 도달 불가 경로였고, 리뷰가 "추가 확인 필요"로 미뤄둔 항목이 유일한 실동작 결함이었다.
**모든 수정 와이어 포맷 무변경, 서버 단독 수정** — 구버전 클라이언트가 그대로 결함에서 복구된다.

#### 19-가. 다중 클라이언트 다운스트림 오배송 (실동작 결함, 실측 확정)

**파일**: `mud_lite.c` / `mud_lite.h` (`peer_id`, `mud_send_*_peer`, `mud_set_path_peer`), `mf_server.cpp`

**증상**: 서버 1개가 클라이언트 2개 이상을 서비스하면 일부 클라이언트의 다운스트림이 통째로 사라진다.
업스트림은 정상이라 진단이 어렵다. 내용 오염(cross-talk)은 발생하지 않는다.

**원인**: 클라이언트는 "peer 1개 + 경로 여러 개"지만 서버는 반대로 "소켓 1개 + 클라이언트 여러 개"다.
`mud_send()`는 `mud_select_path()`로 **전체 경로 표**에서 경로를 고르므로 A의 패킷이 B의 경로로 나간다.
받은 B는 conv가 자기 것이 아니므로 조용히 폐기(`[client] conv not found`) → A 입장에서는 손실.

**모드별 발현** (루프백, 클라이언트 2개, 각 200패킷 왕복):

| multipath-mode | 수정 전 | 수정 후 |
|---|---|---|
| `failover` (기본) | 200 / **0** — 한쪽 완전 불통 | 98% / 100% |
| `duplicate` (운영 설정) | 200 / 198 — 동작하나 **전 클라이언트로 복제(N배 증폭)** | 정상, 증폭 해소 |
| `aggregate` | 98 / 98 — 각자 **자기 몫의 ~1/N만** | 96% / 98% |

운영이 `duplicate`였던 덕에 증상이 증폭 대가로 가려져 있었다. 기존 테스트가 놓친 이유는
`test_scale_sessions.py`의 cross-talk 검사가 wg sink 도착분(**업스트림만**)을 보기 때문이다.

**수정**: `mud_path`에 `peer_id`를 두고, 서버가 수신 시 그 경로를 세션에 귀속시킨 뒤
`mud_send_peer()` / `mud_send_all_peer()` / `mud_send_next_peer()`로 **목적지 세션의 경로 집합에
한정해** 전송한다. 그 집합 안에서는 기존 `--multipath-mode` 정책이 그대로 적용된다.
`peer_id == 0`은 "미태깅 = 전체 매칭"이라 클라이언트 측과 단일 클라이언트 서버는 **동작이 이전과 동일**
(peer 0일 때 가중치 합은 기존 `mud->rate`를 그대로 사용해 선택 결과까지 일치시켰다).

> **다중 POP**: 한 세션이 여러 주소로 도착하므로 매 패킷마다 도착 경로를 재태깅한다.
> 세션 id를 peer id로 그대로 쓰고, 0은 예약값이라 all-zero 세션 id만 1로 접는다.

#### 19-나. `mud_recv()` 반환 패킷의 출처 오판 (19-가의 전제)

**파일**: `mud_lite.c` (`last_remote`, `mud_get_last_remote()`), `mf_server.cpp` (`mud_io_cb`)

`mud_io_cb`는 `recvfrom(MSG_PEEK)`로 송신자 주소를 얻고 나서 `mud_recv()`로 패킷을 소비한다.
그런데 `mud_recv()`는 소켓이 아니라 **자체 recvmmsg 배치 큐(`rq`, 32슬롯)** 에서 패킷을 꺼낸다.
큐에 여러 클라이언트의 패킷이 섞여 있으면 peek이 본 패킷과 `mud_recv()`가 돌려준 패킷이 **다르다**.

결과적으로 `session_id`의 canonical 주소와 경로 태깅이 엉뚱한 클라이언트에 묶였다.
징후는 근거 없는 `[server] session ...: alt path ...` 로그였다(단일 클라이언트에선 무해).
`mud_get_last_remote()`를 추가해 `rq[idx].remote`(실제 출처)를 쓰도록 고쳤고, 이 수정 없이는
19-가의 경로 태깅이 항상 어긋난다. 수정 후 `alt path` 로그 0건.

#### 19-다. `mud_delete()` / `mud_create()` 오류경로 누수

`sq`·`sq_msgs`·`rq`·`rq_msgs` 4블록이 해제되지 않았다. `mud->fd`를 `calloc` 직후 `-1`로 설정해
부분 초기화 객체도 `mud_delete()`가 안전하게 정리하게 하고(기존엔 `fd=0`이라 `mud_delete` 재사용 시
**stdin을 닫을** 위험), `mud_create()`에 5번 중복돼 있던 free 캐스케이드를 `goto err` 하나로 통합했다.

ASAN A/B 실측: 수정 전 **정확히 140,288 B** 누수 리포트 → 수정 후 0건.
호출은 종료 직전 1회뿐이고 재생성 경로가 없어 **실사용 영향은 없었다**(리뷰는 "높음"으로 평가).

#### 19-라. pending 큐 하드닝 + 목적지·TTL 보존

`enqueue_server_pending()` / `enqueue_pending()`(클라이언트)에 `NULL`·음수·버퍼 초과 검증을 추가했다.
호출자가 FEC 인코더 출력뿐이라 현재 도달 불가 경로이므로 하드닝이다(리뷰는 "높음"으로 평가).

아울러 큐 엔트리에 **목적지 peer와 enqueue 시각**을 실었다. 목적지를 flush 시점에 다시 유도할 수 없기
때문이고(리뷰 8번이 지적한 부분), 목적지가 사라진 패킷이 큐 머리를 막지 않도록 **TTL 1초** 초과분만
폐기한다. 처음에는 "peer에 RUNNING 경로가 있는지"로 판정했는데, 경로 상태가 beat마다
RUNNING↔DEGRADED로 흔들려 **살아 있는 트래픽을 버렸다**(400패킷당 28건 손실 실측) → 시간 기준으로 교체.

#### 19-마. obfs 인증 토큰 상수 시간 비교

`memcmp(token, expected, 8)` → `token_equal()`. 허용 슬롯(현재/±1)을 모두 계산한 뒤 결과를 OR 하므로
어느 슬롯이 맞았는지도 수행시간에 남지 않는다. 판정 결과는 동일.

단, 이 시스템에는 타이밍보다 강한 신호가 이미 있다 — 인증 실패 시 내장 QUIC Initial을 **응답**하므로
(§11) 공격자는 응답 유무로 성패를 구분할 수 있고, 그건 액티브 프로빙 대응상 의도된 설계다.
따라서 실질 위험 감소는 작지만 비용도 없다.

#### 19-바. 리뷰 처방을 따르지 않은 것

- **setsockopt 반환값 검사**: 리뷰는 실패 시 `goto err_fd`를 제안했으나 **그대로 적용하면 IPv4 기동이
  전부 실패한다.** IPv4 소켓에 `IPV6_RECVPKTINFO`를 설정하면 설계상 항상 실패한다(실측
  `ENOPROTOOPT`, 반대 조합은 성공). 두 패밀리 옵션을 모두 시도하고 하나가 실패하는 것을 전제로 한
  코드이므로 무시가 맞고, 그 이유를 주석으로 남겼다. 필수인 `fcntl` 비차단 설정만 검증을 추가했다.
- **PRNG 고정시드 / 동시 접근**: 고정시드는 2026-07-24에 검증 후 수정하지 않기로 결정된 사안.
  동시 접근은 스레드를 만들지 않는 단일 이벤트 루프라 현재 무해.
- **pending 큐 만원 정책 통일**: 서버는 최신 폐기, 클라이언트는 최오래 폐기로 엇갈려 있다.
  결함이 아니라 정책 선택이고, 19-라의 TTL 도입으로 큐 머리 막힘은 해소되므로 그대로 두었다.

---

### 20. 보안/성능/누수 리뷰 7건 중 6건 수정 (2026-07-31, v1.0.3)

두 번째 리뷰(보안·성능·누수 관점)를 전부 코드로 검증했다. 리뷰가 High로 올린 3건 중 실제로 운영에
영향이 있는 것은 릴레이 세션 만료였다. **와이어 포맷 무변경.**

> **upstream 예외**: 아래 §20-다는 `packet.cpp` / `connection.{h,cpp}` — UDPspeeder 유래 코드다.
> "upstream 미수정" 원칙의 예외로 반영했다. 판단 근거는 ① 셋 다 명백한 결함(경계 검사 누락·미초기화),
> ② 수정이 각 3~5줄로 국소적, ③ 상위 계층에서 우회 불가. 변경 지점에 이유 주석을 남겼다.

#### 20-가. 릴레이 세션 idle 만료 60초 → 실제 16.7시간 (실동작 결함)

**파일**: `mf_relay.cpp` `cleanup_cb()`

```c
#define RELAY_SESSION_TIMEOUT_MS  60000            /* ms */
if (now - s->last_active > TIMEOUT_MS * 1000LL)    /* ← ms에 다시 ×1000 */
```
`get_current_time()`과 `last_active` 모두 ms(`common.cpp:420`)인데 비교식에서 1000을 더 곱해
60,000,000 ms = **16.7시간**이 됐다. 릴레이는 클라이언트 (src_ip, src_port)마다 **upstream 소켓 +
ev_watcher**를 잡으므로 소스 포트가 계속 바뀌는 환경(NAT 재바인딩, 포트 호핑)에서 FD가 고갈된다.
같은 파일의 decoy 세션은 `time(NULL)` 초 단위로 올바르게 비교해(`> 10`) 두 단위가 섞인 것이 원인.

**A/B 실측** (`test_relay_session_expiry.py`, 세션 12개 생성 후 75초 대기):

| | 세션 생성 후 FD | 75초 후 FD |
|---|---|---|
| 수정 전 | 18 | **18 (회수 없음)** |
| 수정 후 | 18 | **6 (기준 복귀)** |

#### 20-나. `-k` 미지정 시 공개된 기본 키로 동작

`g_key_string`의 기본값이 소스에 박힌 `"default-key"`라, client/server에서 `-k`를 빠뜨리면
**공개 문자열이 그대로 PSK**가 된다. UDP 포트에 도달 가능한 누구나 인증 패킷을 만들 수 있다.
obfs가 켜져 있으면 `-k`를 필수로 요구하고 없으면 기동을 거부하도록 했다(exit 1).
`--disable-obfs`는 PSK 자체가 없으므로 면제, 릴레이는 투명 중계와 `--route` 때문에 기존대로 선택.

> 동작 변경이다. `-k` 없이 뜨던 구성은 이제 기동에 실패한다. 운영 unit은 모두 KEY를 지정하므로 영향 없음.

#### 20-다. upstream 코드 3건 (경계 검사·초기화)

- **`packet.cpp:get_conv()`** — 길이 확인 전에 conv 4바이트를 `memcpy`했다. 호출지
  (`mf_server.cpp`, `mf_client.cpp`) 모두 FEC 디코드 출력을 검사 없이 넘기므로, 출력이 4바이트
  미만이면 유효 데이터 범위를 넘겨 읽는다(큰 정적 버퍼 안이라 크래시 대신 쓰레기 conv id).
  검증을 `memcpy` 앞으로 옮겼다.
- **`connection.cpp:conn_manager_t()`** — `clear_it`을 초기화하지 않고 `clear_conn()`에서 바로
  `it = clear_it`로 사용했다. 표준상 UB지만, 전역 객체가 0으로 초기화되고 libstdc++에서 0인
  iterator가 `end()`와 같게 비교되어 우연히 동작했다. 생성자에서 `mp.end()`로 초기화.
- **`connection.h:conv_manager_t()`** — 생성자가 `long long last_clear_time = 0;`으로 **동명의
  지역 변수**를 선언해 멤버가 초기화되지 않았다. conv cleanup 주기가 미초기화 값에 의존.
  (매 translation unit마다 뜨던 `unused variable 'last_clear_time'` 경고의 정체이기도 하다)

#### 20-라. mud_lite 미초기화·정렬

- `mud_localaddr()`이 family와 주소만 채우고 **포트를 채우지 않아** 호출자의 미초기화 값이
  `mud_unmapv4()`에서 읽히고 `path->conf.local`에 저장됐다. 비교에 포트를 쓰지 않아 무해했지만
  값이 비결정적이었다 → 진입 시 zero 초기화.
- `mud_send_slot` / `mud_recv_slot`의 `ctrl[]`이 2012바이트 `buf[]` 뒤에 와 4바이트 경계에
  놓였는데, `CMSG_*` 매크로는 `struct cmsghdr` 정렬을 요구한다 → 매 송수신마다 UBSan 정렬 위반.
  `__alignof__(struct cmsghdr)` 정렬 지정으로 해소. **이 수정 후 ASAN+UBSAN 완전 클린.**

#### 20-마. 세션 만료 시 경로 태그까지 해제

§19-가의 peer 태깅은 세션 만료 시 canonical 매핑만 지웠고, 경로에 남은 `peer_id`는 그대로였다.
실제 해는 없다(유휴 경로는 RUNNING이 아니게 되어 선택 대상에서 빠지고, 주소가 재사용되면 매 패킷
재태깅된다). 다만 테이블 정합성을 위해 `session_entry_t`에 관측 주소 목록을 두고 만료·축출 시
모두 해제하도록 했다. 아울러 LRU 축출로 매핑이 사라진 살아있는 세션은 다음 패킷에서 재바인딩해,
잠깐이라도 "전체 경로 선택"으로 되돌아가지 않게 했다.

#### 20-바. 빌드

`make clean && make -j`가 실패했다 — `git_version.h`를 만드는 **실제 파일 타깃이 없고**
phony `git_version`과 `all: git_version $(NAME)`의 순서에만 의존해, 병렬 빌드에서 `main.o`가
헤더보다 먼저 시작했다. `git_version.h: FORCE` 파일 타깃으로 바꿨고 `make git_version`은 별칭으로
유지된다. **이 문서 상단의 "make git_version 먼저 실행" 우회 절차는 더 이상 필요 없다.**

`make asan`(ASAN+UBSAN) 타깃을 추가하고 미사용 변수 경고 6건을 정리해 **빌드 경고 0**이 됐다.

---

### 21. 경로 장애 거동 — 죽은 경로 미검출 / dedup 지연차 한계 (2026-07-31, v1.0.4)

격리 netns(veth 2쌍)로 멀티패스 경로 장애를 실측하다 발견. **운영·테스트망이 전부 `duplicate`라
가려져 있었다** — duplicate는 살아있는 경로가 전량을 나르기 때문이다.

#### 21-가. 완전히 끊긴 경로가 배제되지 않음 (aggregate 치명적)

**파일**: `mud_lite.c` — `mud_path_update()`, `MUD_PATH_DEAD_TIMEOUT` 신설

**증상**: 경로 하나가 완전히 끊겨도 `aggregate`가 계속 그 경로로 절반을 보낸다. 스스로 회복하지 않는다.

| 모드 | 유실 (40초 스트림, 10초에 절단, 5000pps, `-f 20:5`) |
|---|---|
| duplicate | 0.04% |
| **aggregate** | **37.73%** |

37.73%는 "끝까지 배제 안 됨"의 이론값(50%×30/40=37.5%)과 일치한다. 1초 내 배제였다면 1.25%다.

**원인** (계측 빌드로 확정): `mud_path_update()`의 DEGRADED 판정이 MTU 프로브 분기에 가로채인다.
```c
if (path->msg.sent >= MUD_MSG_SENT_MAX) {   /* 프로브 5회 무응답 */
    if (path->mtu.probe) {
        mud_update_mtu(path, 0);
        path->msg.sent = 0;                  /* ← 리셋. 결론에 도달하지 못함 */
    } else {
        path->status = MUD_DEGRADED;          /* 여기 와야 배제됨 */
```
매 틱 로그로 `msg.sent`가 **1→2→3→4→5→1** 무한 순환하고 `mtu.probe=1456`이 계속 세팅돼 있음을
확인했다. 탈출구가 하나 더 있지만(`tx.loss > loss_limit` → LOSSY) `tx.loss`는 `mud_update_rl()`이
**프로브 응답 수신 시** 계산하므로 죽은 경로는 영원히 0이다. 두 경로 모두 막힌 구조.
(1초 간격 샘플링에서는 `msg.sent=3` 고정으로 보였는데, 이는 500ms 순환과의 에일리어싱이었다 —
진단 시 샘플링 주기를 주의할 것.)

**수정**: `rx.time` 기반 하드 생존 타임아웃을 MTU 분기 **앞에** 배치.
```c
#define MUD_PATH_DEAD_TIMEOUT (MUD_ONE_SEC)   /* ≈10 beat */
if (path->rx.time && mud_timeout(now, path->rx.time, MUD_PATH_DEAD_TIMEOUT)) {
    path->status = MUD_DEGRADED; return 0;
}
```
`rx.time`은 데이터·프로브 어느 쪽이든 수신 시 갱신되므로 유휴 정상 경로는 걸리지 않는다(프로브를
beat마다 주고받으므로). 신규 경로는 `rx.time==0`으로 제외.

**결과**: aggregate 유실 **37.73% → 1.38%**(검출 ~1.1초분), duplicate 0.04% → 0.02%.
**복구도 확인** — 경로 복원 후 ~0.5초에 DEGRADED→RUNNING 복귀(계측 로그 t=15.0s→2, t=24.0s→6).

#### 21-나. dedup 테이블이 경로 지연차를 못 버팀

**파일**: `mud_lite.c` — `MUD_DEDUP_SIZE` 1024 → **16384**

duplicate에서 두 사본은 `지연차`만큼 벌어져 도착하고, 그 사이 `지연차 × pps`개가 삽입된다.
direct-mapped라 짝의 슬롯이 덮이면 중복이 FEC 디코더까지 통과한다.

| 지연차 30ms | 1024 | 16384 |
|---|---|---|
| 500 pps | 2.7% | 0.2% |
| 2000 pps | 10.9% | 0.7% |
| 5000 pps | **24.0%** | 2.3% |

누출률 ≈ `1.8 × (지연차[초] × pps) ÷ 크기` (실측 11개 지점과 ±3%p 일치).
누출된 중복 자체는 무해하다(FEC는 같은 슬롯 재기록, WireGuard가 replay 거부 — §18-가) —
문제는 수신측이 최대 24%의 불필요한 복호·처리를 한다는 낭비다.

**비용 실측**: RSS **+8KB**(384KB를 calloc하지만 만지지 않은 페이지는 미상주),
**RTT·CPU 변화 없음**(p50 575µs·CPU 50%가 양쪽 동일 — 조회가 O(1) 직접사상이라 비교 횟수가 안 늘고,
캐시 미스 ~100ns는 575µs에 묻힌다). 유일한 대가는 **합성 동일페이로드 오탐** 0.26%→0.37%인데,
실트래픽은 WireGuard 카운터로 매 패킷 바이트가 달라 해당하지 않는다.

#### 21-다. 모드 선택 지침 (실측 근거)

| 상황 | duplicate | aggregate |
|---|---|---|
| 경로 완전 단절 | **0.02%** | 1.38% (v1.0.4 이전 37.7%) |
| 경로 열화(손실 60%) | 0.13% | **0.01%** |
| 지연차 30ms 재정렬 | 없음 | 상시(깊이 150) |
| 중복 누출 | 지연차×pps에 비례 | 없음 |
| 대역폭 | 경로 수만큼 소모 | 합산 |

- **점진적 열화에는 aggregate가 더 강하다** — rate 피드백이 나쁜 경로 몫을 줄이고 FEC가 덮는다.
  aggregate의 약점은 "느려짐"이 아니라 "갑작스런 단절"이었고 그것이 21-가 수정 대상이었다.
- **duplicate의 대역폭 대가는 실측 약 3배**(3경로 기준, §20 측정). 유효 용량이 1/3로 깎여 용량
  초과 드롭이 그만큼 일찍 온다.
- **국제 고속 구간에서 duplicate는 부적절**하다. 지연차가 크고 pps가 높아 중복 누출이 급증하고
  (테이블을 키워도 한계) 비싼 회선을 배로 쓴다. 그 구간은 `aggregate`가 맞고, v1.0.4의 생존
  타임아웃이 있어야 안전하다.

---

### 22. 와이어 바이트로 FEC 디코더 abort / 릴레이 세션 상한 없음 (2026-08-01, v1.0.5)

수신측 입력 검증 2건. **와이어 포맷 무변경**이고 둘 다 수신측 단독 수정이라 상대편을 그대로 두고
한쪽만 교체할 수 있다.

> **upstream 예외**: §22-가는 `fec_manager.cpp` — UDPspeeder 유래 코드다. §20-다와 같은 사유로
> 예외 적용했다. ① 경계 검사 누락이라는 명백한 결함, ② 수정이 국소적, ③ 상위 계층에서 우회 불가
> (FEC 디코더는 입력을 자기가 파싱한다). 변경 지점에 이유 주석을 남겼다.

#### 22-가. 검증되지 않은 `inner_index` / `type` 으로 FEC(RS) 디코더가 abort

**파일**: `fec_manager.cpp` `fec_decode_manager_t::input()`, `Makefile`(`-UNDEBUG`)

**원인**: FEC 8바이트 헤더의 `type` / `inner_index` 를 검증 없이 그대로 썼다. `inner_index` 에
상한이 없으면 그룹에 존재하지 않는 슬롯이 "채워진 것"으로 집계되어 `about_to_fec` 이 성립하고,
정작 복원에 필요한 조각은 모자란 상태로 `rs_decode2()` 가 -1 을 반환한다. 그 반환값이
**`assert()` 안**에 있었다 — "이 줄은 항상 성공한다"는 전제였지만 그룹 구성은 와이어 바이트로
정해지므로 전제가 성립하지 않고, 결과는 프로세스 abort다.

obfs 인증 토큰은 `SipHash(시간슬롯, PSK)`라 **페이로드를 인증하지 않고**, CRC 경로
(`do_cook`/`de_cook`)도 이 프로젝트에서는 쓰지 않는다. 즉 디코더에 도달하는 바이트는 사실상
무검증 입력이다.

**수정**:
- `type` 은 0(mode 0) / 1(mode 1) 만 허용. 2(RNLC)는 `misc.cpp` 에서 이미 분기되어 여기 오지
  않고, 3 이상은 코드상 `type==1` 로 취급되므로 함께 거른다.
- `inner_index` 상한 검사. mode 1 의 systematic 패킷은 그룹 파라미터를 아직 모르는 상태로
  나가므로(`data_num=0`) 그 경우엔 배열 한계만 보고, 그룹 파라미터가 확정된 뒤 다시 확인한다.
- `rs_decode2()` 두 곳의 `assert` 를 반환값 검사로 바꿔 실패 시 **그룹만 폐기**한다
  (`anti_replay.set_invaild(seq)` 후 정상 종료 경로). 파라미터를 모르는 동안 먼저 도착한 패킷은
  검증할 수 없으므로 상한 검사만으로는 부족하고, 이 반환값 확인이 최종 방어선이다.
- `Makefile` 에 **`-UNDEBUG`** 추가. 이 코드에는 `assert` 안에서 부작용이 있는 호출
  (`input()`/`output()`/`exist()`)이 남아 있어 `NDEBUG` 가 정의되면 **그 호출 자체가 사라져**
  인코딩·큐 처리가 조용히 누락된다. 패키징 환경이 `-DNDEBUG` 를 주입해도 무력화되게 명시 해제했다.

**실측** (`test_fec_decode_bounds`, 디코더에 직접 주입):

| 입력 | 수정 전 | 수정 후 |
|---|---|---|
| `type=0 x=1 y=0 inner_index=200` | **abort** (assert 실패) | `-1` 드롭, 출력 0 |
| `type=3` | 통과(type==1 취급) | `-1` 드롭 |
| `inner_index == x+y` (경계 바로 밖) | 통과 | `-1` 드롭 |
| `type=0 inner_index=0` (정상) | 통과 | 통과 (거부 안 됨 확인) |
| mode 1 systematic `data_num=0 inner=5` (정상) | 통과 | 통과 |

7/7 통과. 전체 회귀도 정상(RNLC 11/11, CLI 90/90, 릴레이 라우팅 7/7, RNLC e2e 9/9,
성능·안정성 26/26, 다운스트림 다중 24/24).

#### 22-나. 릴레이 동시 세션 상한 없음 → FD 고갈

**파일**: `mf_relay.cpp` — `RELAY_SESSION_MAX`, `session_sweep()`, `session_reserve_slot()`

**원인**: 릴레이는 세션 하나가 **upstream 소켓 + `ev_io` watcher** 를 하나씩 잡으므로 세션 수가
곧 FD 수다. v1.0.3에서 idle 만료(60초)를 고쳤지만 **동시 상한이 없어**, 소스 포트를 계속 바꿔가며
보내면 만료가 오기 전에 FD 가 고갈된다. 특히 `-k`/`--route` 없이 `--upstream` 만 준 투명 중계
모드에서는 HMAC 검증이 없어 누구나 세션을 만들 수 있다. 서버는 v1.0.3에서 `SESSION_MAX` + LRU
축출을 갖췄는데(§18-나) **릴레이만 빠져 있었다.**

**수정**: `RELAY_SESSION_MAX = max_conn_num * 4`(기본 800) 도입. 소켓을 할당하기 **전에** 검사하고,
먼저 sweep 해서 유휴분을 회수한 뒤 그래도 모자라면 **LRU 를 축출**한다 — 그래야 순간적인 버스트가
살아 있는 세션을 밀어내지 않고, 반대로 플러딩이 기존 클라이언트를 굶기지도 않는다. 슬롯을 못 비우면
패킷을 버린다. `cleanup_cb()` 의 sweep 로직은 `session_sweep()` 으로 추출해 양쪽이 공유한다.

값은 서버와 같게 맞췄다. 800 세션 = 800 FD 로, 기본 `RLIMIT_NOFILE`(1024) 안에 리슨·타이머·decoy
몫을 남긴다.

**A/B 실측** (`test_relay_session_cap.py`, 서로 다른 소스 포트 1000개에서 각 1패킷):

| | 세션 수 | 프로세스 FD |
|---|---|---|
| 수정 전 | **1000 (요청한 만큼 그대로)** | 1006 |
| 수정 후 | **800 (상한)** | 806 |

상한에 도달한 뒤에도 신규 클라이언트가 계속 서비스된다(LRU 축출로 1000패킷 전부 upstream 도달).
`RLIMIT_NOFILE` 이 기본값(1024)인 환경이라면 수정 전은 고갈에 이른다 — 측정 머신은 한도가
1,048,576이라 고갈 대신 "무제한 증가"로 관측됐다.

---

### 23. PSK가 로그에 평문으로 기록됨 (2026-08-01, v1.0.6)

**파일**: `obfs.h` / `obfs.cpp`(`obfs_key_fingerprint()` 신설), `main.cpp`, `mf_relay.cpp`, `misc.cpp`

**증상**: `--route` 로 등록한 키가 **info 레벨**로 평문 출력됐다. 기본 로그 레벨이 4(info+)이고
운영은 systemd 로 돌리므로 **journald 에 영구 보관**된다 — 로그를 읽을 수 있는 사람 누구에게나
PSK 가 넘어간다. 로그 파일 반출·지원 티켓 첨부·백업으로도 퍼진다.

```
route added: key=MySecretKey upstream=1.2.3.4:443            ← main.cpp
[relay]   route[0] key=MySecretKey upstream=1.2.3.4:443      ← mf_relay.cpp
```

**확인한 범위**: `-k` 로 준 PSK 자체는 어디에도 로깅되지 않았다(`main.cpp` 의 `case 'k'` 는 저장만
한다). 노출은 `--route` 키뿐이며, 위 두 줄이 유일한 실제 경로였다.

**수정**: 되돌릴 수 없는 짧은 지문으로 대체했다.

```c
#define OBFS_KEY_FP_LEN 12       /* "kf:" + 8 hex + NUL */
void obfs_key_fingerprint(const char *key_str, char *out, size_t out_len);
/* → "kf:330d27b8" (키 없음: "kf:-") */
```

`derive_psk()` 와 같은 SipHash 를 쓰지만 **파생 상수를 분리**했다 — 지문은 로그로 나가므로 와이어에
쓰이는 값의 접두사가 되어선 안 된다. 같은 키는 항상 같은 지문이라 **어느 키에 관한 줄인지 구분하고
상대 설정과 대조**할 수 있다. 애초에 키를 찍던 이유가 그것뿐이었다.

**한계 (의도한 것)**: 지문은 식별자이고 커밋이 아니다. 32비트만 노출되며, 후보 키를 이미 가진
사람은 지문으로 그 추측을 확인할 수 있다. 키를 추측할 수 있는 상대에게는 로그 줄이 필요 없으므로
받아들일 만한 성질이다. 또 `-k`/`--route` 는 CLI 인자이므로 **`ps` 출력과 systemd unit 파일에는
여전히 키가 보인다** — 이 수정의 범위는 로그다.

**함께 처리 (도달 불가, 예방적)**: `misc.cpp` `process_arg()` 는 명령행 전체를 info 로 덤프하고
`key=%s` 를 debug 로 찍었다. **호출부가 없어**(multi-fec 은 `main.cpp:parse_args()` 로 파싱) 현재
실행 경로가 아니지만, 나중에 연결하면 조용히 키를 흘리게 되므로 값 부분을 `<redacted>` 로 가리고
debug 줄도 지문으로 바꿨다. `-k SECRET` / `-kSECRET` / `--key[=]SECRET` / `--route[=]"key ip:port"`
네 형태를 모두 처리한다.

**운영 조치**: 이미 기록된 로그에는 평문 키가 남아 있다. 바이너리 교체만으로 사라지지 않으므로,
노출 범위가 신경 쓰이면 **키 교체**(양쪽 동시)나 journal 정리를 별도로 해야 한다.

**회귀 방지**: `test_relay_routing.py` TC6 — 기동 로그에 키 평문이 없고 키별 지문이 기록되는지
확인(9/9). 전 스위트 통과.

---

### 24. 경로 손실률이 서로 반대 방향의 카운터로 계산됨 (2026-08-01, v1.0.7)

FEC 파라미터 튜닝 측정 중 `path[0]`이 부하만 걸리면 LOSSY로 떨어져 duplicate가 한 경로로
축소되는 것을 발견해 역추적했다. **와이어 포맷 무변경** — probe가 싣는 필드는 그대로이고
수신측 해석만 바뀐다. 한쪽만 교체해도 된다.

**증상**: netem 10%가 걸린 경로가 `loss=93%`로 보고돼 `MUD_LOSSY`(임계 200/255 = 78.4%)로
떨어지고, 그 상태에서 나오지 못한다. duplicate가 사실상 failover가 되고 aggregate는 대역폭이
반토막 난다. 유휴에서는 정상값(5~16%)을 보이므로 부하를 걸어야만 재현된다.

```
22:19:50  path[0] RUNNING  loss=15%  tx=168668 rx=146894   ← 유휴, 정상
22:20:20  path[0] LOSSY    loss=93%  tx=169238 rx=147333   ← 부하 시작 ~8초 후
22:21:20  path[0] LOSSY    loss=94%  tx=170148 rx=148169   ← +455/30s = probe 만
```

누적 실손실은 `(170148−148169)/170148 = 12.9%`로 netem과 맞는다. **보고값만 틀렸다.**

#### 24-가. `tx.loss`가 peer의 송신 수와 peer의 수신 수를 비교했다

**파일**: `mud_lite.c` `mud_update_rl()`, `mud_lite.h` (`msg.loss_tx_acc` / `msg.loss_rx_acc` 신설)

```c
/* 수정 전 */
uint64_t tx_acc = tx_total - path->msg.tx.acc;
uint64_t rx_acc = rx_total - path->msg.rx.acc;
if (tx_acc && rx_acc <= tx_acc)
    path->tx.loss = (tx_acc - rx_acc) * 255U / tx_acc;
```

`tx_total`·`rx_total`은 **둘 다 peer의 probe에서 읽은 값**이다(`mud_recv_msg()`). 즉
`(peer가 보낸 수 − peer가 받은 수) ÷ peer가 보낸 수` — **같은 쪽의 서로 반대 방향 카운터**다.
손실률은 "한쪽이 보낸 수 vs 반대쪽이 받은 수"여야 하고, 필요한 `path->tx.total`은
`mud_send_path()`에서 정확히 유지되고 있는데 쓰이지 않았다.

**유휴에서는 우연히 맞는다.** probe는 받으면 즉시 답신하므로 양방향 패킷 수가 균형을 이뤄
실측으로 수렴한다 — 이 결함이 오래 드러나지 않은 이유이고, 진단 시 유휴 상태만 보면 정상으로
보이는 이유다. **트래픽이 비대칭이 되는 순간 방향 불균형을 손실로 보고한다.**

**수정**: 각 방향을 반대쪽 카운터와 짝지어 계산한다. 자기 카운터 스냅샷용으로 `msg` 구조체에
`loss_tx_acc` / `loss_rx_acc` 2개를 추가했다(기존 `msg.tx.acc` / `msg.rx.acc`는 peer 미러라
의미를 그대로 뒀다).

```c
uint64_t tx_acc = path->tx.total - path->msg.loss_tx_acc; /* 내가 보낸 수   */
uint64_t rx_acc = rx_total       - path->msg.rx.acc;      /* peer 가 받은 수 */
if (tx_acc)
    path->tx.loss = rx_acc >= tx_acc ? 0 : (tx_acc - rx_acc) * 255U / tx_acc;
```

현재 probe는 `path->rx.total` 증가 **전에** 처리되지만 스냅샷도 같은 지점에서 뜨므로 상쇄된다.
남는 편차는 probe 도착 시점의 in-flight(≈1 RTT분)가 손실로 잡히는 것인데, 1초 창에 RTT
25~40ms면 3~4% 수준이라 78.4% 임계에 영향이 없다.

#### 24-나. `path->rx.loss`가 한 번도 대입되지 않았다

`mud_path_update()`의 LOSSY 판정은 `tx.loss > limit || rx.loss > limit`인데 `rx.loss`는
**읽기만 하고 어디서도 쓰지 않아** 상시 0이었다. 판정식 절반이 죽은 코드였다.
`(peer 송신 수 − 내 수신 수) ÷ peer 송신 수`로 채웠다.

#### 24-다. 래치 — 한 번 걸리면 풀리지 않는다

LOSSY 경로는 모든 송신 함수에서 제외된다(`mud_send_all` / `mud_send_next` / `mud_select_path`
등 6곳의 `status != MUD_RUNNING → continue`). 그러면:

1. 클라이언트 path0 LOSSY → 데이터 송신 중단, probe만 남음
2. 서버는 자기 판단으로 path0에 하향 데이터를 계속 보냄
3. 다음 probe의 서버 카운터: tx 델타 큼(하향 데이터) / rx 델타 작음(probe뿐)
4. → 비율이 더 올라가 **LOSSY 유지**

수치가 맞는다: 하향 1 Mbps ÷ 1200B × FEC 1.33 ≈ 138 pps + probe 10 = ~148, 서버 수신은
클라이언트 probe ~9 pps → `(148−9)/148 = 93.9%`. 관측 93~94%.

`rx_acc <= tx_acc` 가드도 한몫했다 — 조건이 깨지는 창에서 갱신을 **통째로 건너뛰어** 직전 값이
남았다. 손실이 관측되지 않으면 0으로 갱신하도록 바꿔 이 경로를 끊었다.

#### 24-라. 검증

`test_path_loss_unit.c` (`make test-path-loss`) — `mud_update_rl()`이 static이라 `mud_lite.c`를
통째로 include해 직접 구동한다. **10/10 통과**, 같은 테스트를 수정 전 코드에 돌리면 **5/10 실패**:

| 케이스 | 수정 전 | 수정 후 |
|---|---|---|
| 대칭 무손실 | 0 | 0 |
| 상향 10% 손실 (대칭 트래픽) | 25 | 25 ← 균형 상태에선 원래 맞았다 |
| **하향 10% 손실 → `rx.loss`** | **0** (미대입) | **25** |
| **비대칭 (하향 데이터만, 실제 상향 손실 10%)** | **239** = 93.7% | **25** = 10% |
| **높은 손실 후 회복 → 0 복귀** | **236** (래치) | **0** |
| 송신 0인 창 → 직전 값 유지 | 255 | 25 (유지) |

전체 회귀: RNLC 유닛 11/11, FEC 경계 7/7, CLI 90/90, 릴레이 라우팅 9/9, RNLC e2e 9/9,
다운스트림 다중 24/24. 빌드 경고 0.

> **부수 수정**: `make test-fec-bounds`가 v1.0.6부터 링크 실패했다 — `misc.o`가 §23에서 추가한
> `obfs_key_fingerprint()`를 참조하는데 `FEC_BOUNDS_TEST_OBJS`에 `obfs.o`가 없었다. 추가했다.

**측정 근거**: `test-results/2026-08-01-fec-tuning/REPORT.md` §11-다.
**미반영**: 테스트망 배포본은 아직 v1.0.6이라 래치가 그대로 있다.

---

### 25. dedup 된 사본이 경로 수신 카운터에 안 잡혀 느린 경로가 배제됨 (2026-08-02, v1.0.8)

**파일**: `mud_lite.c` — `mud_recv()` 데이터 패킷 경로

§24-나에서 `rx.loss`를 살린 직후 테스트망 검증에서 드러난 후속 결함이다. **와이어 무변경.**

**증상**: duplicate 2경로에 편도 25ms/5%(path[0]), 30ms/2%(path[1]) 임피어먼트를 걸었더니
**손실이 낮은 path[1]이 LOSSY로 배제**됐다. 로그의 `loss=31%`(≈79/255)는 임계 200을 넘지
않으므로 `tx.loss`가 아니라 **`rx.loss`가 트립**시킨 것이다(로그는 `tx.loss`만 찍는다).

**원인**: `mud_recv()`가 중복 사본을 버릴 때 `return 0` 하는 지점이 `path->rx.total++` **앞**이었다.

```c
if (중복) return 0;          /* ← 여기서 반환 */
...
path->rx.total++;            /* ← 여기까지 못 옴 */
path->rx.time   = now;
path->rx.bytes += decoded_size;
```

duplicate에서 두 사본은 경로 지연차만큼 벌어져 도착하고 **느린 쪽이 항상 두 번째**다. 그 사본은
매번 dedup에 걸리므로 느린 경로의 `rx.total`은 probe 분량만 늘고, `rx.loss = (peer 송신 −
내 수신)/peer 송신`이 100%에 가깝게 나온다. `rx.loss`가 죽은 코드였던 v1.0.6까지는 무해했고,
v1.0.7이 이를 판정에 연결하면서 발현했다.

**수정**: 경로 카운팅을 dedup 판정 **앞으로** 이동. 중복 사본도 **그 경로로 실제 도착한 것**이므로
폐기는 전달 계층의 결정이지 경로 손실이 아니다.

**함께 해소된 것**: `path->rx.time`도 같은 이유로 갱신되지 않았다. 이 값은 §21-가의
`MUD_PATH_DEAD_TIMEOUT` 생존 판정을 구동하므로, **사본이 전부 dedup되는 경로는 살아 있는데도
죽은 것으로 판정될 수 있었다.** `rx.bytes`는 rate 추정에 쓰이는데, 실제로 도착한 바이트를 세는
쪽이 맞다.

> **교훈**: 오래 죽어 있던 코드를 살릴 때는 그 값을 공급하는 경로가 그동안 정확했는지 함께
> 확인해야 한다. `rx.loss`는 계산식만 없었던 게 아니라 **입력 카운터도 duplicate 모드에서
> 틀려 있었다.** §24의 유닛 테스트는 `mud_update_rl()`만 구동하므로 `mud_recv()`의 dedup 경로를
> 타지 않아 이 결함을 잡지 못했다 — 실측 검증이 잡았다.

---

### 26. 릴레이 upstream 소스 IP 고정 — `--upstream-local` (2026-08-05, v1.1.0)

**파일**: `main.cpp`, `mf_relay.cpp`(`new_upstream_fd()`), `mf_common.h`

**배경**: 릴레이는 소켓을 **두 개** 쓰고 둘의 바인딩 상태가 다르다. 이 비대칭이 문서에 없었다.

| 구간 | 소켓 | 바인딩 | 소스 IP 결정 주체 |
|---|---|---|---|
| `c ↔ r` | `listen_fd` | `bind(-l 주소)` | 바인딩된 주소 |
| `r → s` | `upstream_fd` | **없음** (`connect()` 만) | 커널 라우팅 preferred source |

즉 `-l 192.168.100.86:443` 으로 띄운 인스턴스도 upstream 은 **`.85` 에서 나갔다**(테스트망 실측:
두 인스턴스가 `192.168.100.85:54374` / `192.168.100.85:59100`). 클라이언트가 쓴 목적지 IP 를
upstream 소켓으로 넘기는 코드가 없고, `.85` 가 `ens18` 의 preferred source 이기 때문이다
(`ip route get 192.168.200.254` → `src 192.168.100.85`). 결과적으로 **`r↔s` 구간에서 두 경로는
소스 IP 로 구분되지 않는다** — 그리고 당시에는 그 위에 **gw 의 SNAT** 가 겹쳐 있어
`s` 에서는 애초에 릴레이 IP 자체가 보이지 않았다(§테스트망 구성도 경고).

> **후속 (2026-08-05)**: `s` 리슨이 `192.168.100.84` 로 옮겨져 `r↔s` 가 온링크가 됐다.
> SNAT 가 우회되어 **이제 `s` 가 릴레이 실제 IP 를 직접 본다** — 즉 `--upstream-local` 의
> 효과가 `s` 에서도 관측된다(아직 배포 전이라 두 인스턴스가 둘 다 `.85` 에서 나간다).
> 아래 본문의 `.254` 는 발견 당시 기록이다. — 경로별로 계측·임피어먼트를 걸 수 없다(현재 netem 은 온링크인
`c↔r` 구간에만 있다).

**추가**: `--upstream-local ip` — `connect()` 앞에 `bind()`. 기본값은 미설정이라 **기존 거동과
바이트 단위로 동일**하다(전역 `address_t` 가 invalid → `if` 하나만 거짓으로 지나간다).

설계 판단 3가지:
- **포트는 받지 않는다.** 릴레이는 upstream 소켓을 **클라이언트 세션마다 하나씩** 만들므로
  고정 소스 포트는 두 번째 세션에서 bind 충돌한다. `ip:port` 를 주면 이유를 붙여 기동을 거부한다.
- **bind 실패는 그 세션을 버린다.** 다른 주소로 대체 전송하면 요청한 고정이 조용히 무력화된다.
- **릴레이 모드 전용.** 다른 모드에서 무시하면 먹은 것처럼 보이므로 기동 거부(클라이언트는
  `--path <local>:<remote>:<port>` 의 첫 필드가 이미 같은 일을 한다).

**검증** (sv1 루프백 11/11): 옵션 없음 → `127.0.0.1`, `--upstream-local 127.0.0.2/.3` → 각각
`.2`/`.3`, `--route` 모드에서도 적용, 로컬에 없는 IP → upstream 미도달 + `bind upstream source`
경고, `ip:port`·client/server 모드·잘못된 IP 는 기동 거부. **세션 300개 A/B** 로 반복
`bind(port 0)` 이 안전함을 확인(양쪽 300/300, 서로 다른 소스 포트 300개, bind 실패 0).

> 첫 300세션 시도가 222/300 으로 나왔는데 **테스트 하네스 수신 소켓의 rcvbuf 오버플로**였다
> (`SO_RCVBUF` 를 키우면 옵션 유무 무관 300/300). 하네스 손실을 피검체 결함으로 읽지 않도록
> 반드시 A/B 로 볼 것 — §측정 하네스 함정과 같은 부류다.

**회귀**: 유닛 10/10·7/7·11/11, CLI 90/90, 릴레이 라우팅 9/9, 세션 상한 4/4, 세션 만료 통과,
다운스트림 다중 24/24, RNLC e2e 9/9, 성능·안정성 26/26. 빌드 경고 0.

---

### 27. 서버 다중 IP 서비스 — `--accept-local` (2026-08-05, v1.2.0)

**파일**: `mud_lite.h`/`mud_lite.c`(`accept_local`, `mud_add_accept_local()`, `err.local`), `main.cpp`

**배경**: 서버 인스턴스 하나로 IP 2개 이상을 서비스해야 할 때(인터페이스 2개, ISP 2회선).

**"진짜 2개 바인드"는 불가능하다.** mud 는 소켓이 하나(`mud->fd`)이고 `mud_create()` 가
`bind()` 를 1회만 한다. fd 를 2개로 늘리려면 **`sendmmsg` 가 fd 당 배치**이므로 전송 큐
(`sq`/`sq_msgs`)까지 fd 별로 쪼개야 하고, 송수신 17개 지점이 `mud->fd` 를 직접 참조한다.
→ **`-l 0.0.0.0` 와일드카드 + 수신 로컬 주소 화이트리스트**가 답이고, 이것이 mud 의 설계
의도다(`IP_PKTINFO` 로 받은 주소를 경로별로 기억해 같은 주소로 응답 — §26 표 참고).

**동작**: `mud_recv()` 가 `mud_localaddr()` 로 얻은 로컬 주소를 목록과 대조해 없으면 폐기하고
`err.local` 카운터를 올린다. 목록이 비면(기본) 전부 수락 = **기존 동작**.

**설계 판단**:
- **미일치 패킷은 조용히 폐기.** 내장 QUIC Initial 로 응답하면 서비스하지 않는 주소에서
  서비스 존재를 광고하게 된다(§11 과 상충).
- **`-l` 이 고정 IP면 불일치 항목은 기동 거부.** 커널이 이미 제한하므로 영구히 하나도 맞지
  않고, 결과가 "전 트래픽 무로그 폐기"라 진단이 가장 어렵다. 전부 일치하면 통과시키되 중복
  경고를 남긴다.
- **상한 16개, 초과는 기동 거부**(조용한 절단 금지). 16 이면 `/28`(가용 14)을 덮는다.
  조회는 수신 패킷당 선형 스캔이라 상수를 작게 유지했다.
- **서버 모드 전용.** 클라이언트는 `--path` 첫 필드가 이미 로컬을 고정하고, 릴레이 리슨
  소켓은 mud 밖이라(`IP_PKTINFO` 미설정) 받아도 아무 일이 없다 → 거부.
- **호스트에 없는 주소는 경고만.** 떠다니는 VIP 가 나중에 붙을 수 있다. 오타로 전 트래픽이
  사라지는 것을 막는 용도.

**⚠️ 방화벽이 오히려 더 조용하다.** 서비스 안 하는 주소로 프로브가 오면 — 진짜 2개 바인드는
리스너가 없어 **커널이 ICMP port unreachable** 을 흘리고, 와일드카드+폐기(이 옵션 또는
iptables DROP)는 **무응답**이다. 액티브 프로빙 대응(§7·§11)이 설계 목표이므로 이 차이가 중요하다.
운영에서 즉시 범위를 바꿀 수 있다는 점에서 iptables 쪽이 나은 경우도 많다.

**멀티홈 필수 조건 (코드 밖)**: mud 는 `ipi_spec_dst` 만 채우고 **`ipi_ifindex` 는 0** 으로
둔다(`mud_lite.c:489`) → 커널이 목적지 기준으로 라우팅한다. 인터페이스가 2개면 **policy
routing 이 필수**다(소스별 `ip rule` + 테이블). 없으면 `IP_B` 소스 응답이 default(`IF_A`)로
나가 ISP 가 버린다. 클라이언트의 §8 과 같은 구조. `rp_filter` 는 loose(2) 필요.
호스트에 포괄 SNAT 룰(`oifname X snat to ...`)이 있으면 mud 가 고른 소스를 덮어쓰므로 예외 필요.

**검증** (sv1 루프백 17/17): 목록 IP 수락·그 외 폐기, 2개 동시, 미지정 시 전부 수락,
`-l` 고정 IP × (미지정/일치/불일치), 상한 16/17, `ip:port`·client·relay 거부, 미존재 주소 경고.
관측은 릴레이 upstream 소켓의 `connect()` 소스 필터링을 이용했다(sv1 에 sudo 가 없어 tcpdump
불가) — 왕복 성공이 곧 "받은 IP 로 응답했다"는 증거다.

**회귀**: 유닛 10/10·7/7·11/11, CLI 90/90, 릴레이 라우팅 9/9, 세션 상한 4/4,
다운스트림 다중 24/24. 빌드 경고 0.

---

### 28. 동시 피어 32 상한이 조용히 끊는다 — 진단 추가 (2026-08-06, v1.3.0)

**파일**: `mud_lite.h`(`err.path_full`), `mud_lite.c`(`mud_recv()`), `mf_server.cpp`(`session_cleanup_cb()`)

**증상**: 동시 클라이언트가 32를 넘으면 **33번째부터 전달이 0**이 되는데 로그·카운터가 전혀
없다. 실측(sv1 루프백, 클라이언트를 1→36 으로 증설):

```
클라# 1~32   왕복 10/10   ok
클라# 33     왕복  0/10   ✗
클라# 34~36  왕복  0/10   ✗
```

**원인**: 서버 mud 의 경로 식별자가 `(local, remote_ip, remote_port)` 이고 클라이언트마다
소스 포트가 다르므로 **클라이언트 1개 = 경로 슬롯 1개**다. `MUD_PATH_MAX` 를 넘으면
`mud_get_path()` 가 NULL → `mud_recv()` 가 0 → 폐기. `mf_server` 는 이 경우를 `log_trace`
(레벨 6)로만 찍는데 운영은 레벨 4다.

**세 상한이 25배 어긋나 있다** — 이게 오해를 키운다:

```
릴레이 동시 세션   RELAY_SESSION_MAX = max_conn_num × 4 = 800
서버 세션 테이블   SESSION_MAX       = max_conn_num × 4 = 800
서버 mud 경로 슬롯 MUD_PATH_MAX      =                    32   ← 먼저 막힌다
```

릴레이 세션 1개 = upstream 소켓 1개 = 서버가 보는 소스포트 1개 = 슬롯 1개이므로
릴레이 경유든 직결이든 같다.

**이번 변경은 진단만이다** — `mud_errors` 에 `path_full`(주소·시각·횟수)을 추가하고,
서버가 30초 세션 sweep 타이머에서 카운트가 늘었을 때만 `log_warn` 한다(폭주해도 로그가
넘치지 않게 드롭 시점이 아니라 주기 보고).

```
[WARN][server] mud 경로 테이블 소진 (상한 32) — 최근 주기에 394 건 폐기,
               마지막 피어 127.0.0.1:35282. 동시 피어가 32 를 넘으면 신규 클라이언트가 조용히 끊긴다
```

**상한 자체는 올리지 않았다.** `sizeof(struct mud_path) = 416 B` 라 1024개도 416 KB 로 메모리는
사소하지만, `mud_get_path()` 와 송신 경로 선택이 **전 슬롯 선형 스캔**이라 패킷당 비용이 비례해
오른다. 800 으로 올리면 스캔이 25배가 되므로 그 비용을 재기 전에는 올리지 않는다.

**내가 틀렸던 것 (기록)**: 이 조사는 "슬롯 8개가 영구 소모된다" 는 가설로 시작했는데 **둘 다
틀렸다.** ① `MUD_PATH_MAX` 는 8이 아니라 **32** 다 — 이 문서의 참조표가 8로 잘못 적혀 있었고
그걸 믿었다(이번에 정정). ② 슬롯은 **회수된다** — `mud_path_update()` 가 5분 무수신 PASSIVE
경로를 `memset(path, 0, ...)` 로 지운다. 상태를 리터럴 `MUD_EMPTY` 로 대입하지 않고 구조체를
0으로 미는 코드라, 토큰 `MUD_EMPTY` 로만 grep 해서 못 봤다. **코드 사실은 문서가 아니라 코드로
확인하고, "없다" 는 grep 한 번으로 결론짓지 말 것.**

---

**테스트 스크립트:**
- `test_path_slots_unit.c` — mud 경로 슬롯 재사용 유닛 검증. `mud_lite.c` 를 통째로 include 해 `mud_get_path()` 를 직접 구동한다. 32개 확보 → 33번째 NULL → 5분 경과 시뮬 후 전량 회수 확인. §28 근거
- `test_concurrent_clients.py` — 동시 클라이언트 상한 실측. 1→36 으로 늘리며 각자 왕복을 확인해 33번째 절벽을 재현한다. **sv1 루프백 전용**(테스트망 무관), 클라이언트 36개 ≈ RSS 1.3 GB
- `test_path_loss_unit.c` — 경로 손실률 계산 유닛 테스트 10개 케이스 (`make test-path-loss`). §24 회귀 방지. **주의**: `mud_update_rl()`만 직접 구동하므로 `mud_recv()`의 dedup 경로(§25)는 커버하지 않는다.
- `test_fec_decode_bounds.cpp` — FEC(RS) 디코더 경계 검사 7개 케이스 (`make test-fec-bounds`). §22-가 회귀 방지.
- `test_relay_session_cap.py` — 릴레이 동시 세션 상한·LRU 축출 4개 케이스. §22-나 회귀 방지. `BIN=` 로 A/B 비교 가능.
- `test_path_failure.py` — 경로 절단·열화·지연차 × duplicate/aggregate 8종. §21-가 회귀 방지. **root 필요**(격리 netns 생성, 운영 무영향).
- `test_relay_session_expiry.py` — 릴레이 idle 세션 만료로 FD가 실제 회수되는지 검증. §20-가 회귀 방지.
- `test_downstream_multi.py` — 다중 클라이언트 **다운스트림** 전달 검증 (모드 4종 × 세션 1/2/4 × FEC on/off = 24 케이스). 기존 스위트가 업스트림만 보던 공백을 메운다. §19-가 회귀 방지.
- `test_relay_routing.py` — 릴레이 키별 라우팅 9개 케이스 (TC6 = 로그에 PSK 평문 없음, §23 회귀 방지)
- `mf_ladder2.sh` (`test-results/2026-08-01-fec-tuning/`) — 테스트망 부하 계단 하네스 v2. TCP 는 `--fq-rate` 커널 페이싱, 워치독 트립 시 캡 절반 자동 재시도. **테스트망에서만 실행**
- `mf_ladder_udp.sh` (`test-results/2026-08-06-postmove-loadtest/`) — 앱 레이트 계단으로 무릎점을 찾는다. **가드를 먼저 띄우고 실행한다**(스크립트가 가드를 띄우지 않고, 가드가 없으면 중단). UDP 고정 레이트라 손실이 그대로 보인다. ⚠️ iperf3 요약 줄은 `NF=13` 이고 실효는 `$7` 이다 — `$(NF-4)` 같은 상대 인덱스를 쓰면 지터를 실효로 읽는다. CPU 는 1초 창 편차가 ±5~9p 라 3회 평균한다. **테스트망에서만 실행**
- `rps_ab.sh` (`test-results/2026-08-06-postmove-loadtest/`) — `rps_cpus` A/B 하네스. **결과는 개선 없음**(2026-08-06). 하네스 교훈 두 개가 코드에 박혀 있다 — 가드 생존은 **argv[1]** 로 판정하고(`pgrep -f mf_gwguard` 는 호출 셸을 잡는다), `wait` 는 **반드시 특정 PID** 로 한다(인자 없는 `wait` 는 같은 셸의 가드까지 기다려 멈춘다). **테스트망에서만 실행**
- `ifbytes.sh` (`test-results/2026-08-06-postmove-loadtest/`) — 전 인터페이스 **누적 바이트** 스냅샷·차분. 장구간 트래픽 격리 확인용(유휴 구간과 부하 구간을 같은 조건으로 재서 차를 본다). **테스트망에서만 실행**
- `ifdelta.sh` (`test-results/2026-08-06-postmove-loadtest/`) — 전 호스트 전 인터페이스 RX/TX 델타. 시험 트래픽이 테스트망 밖으로 새는지 확인하는 데 쓴다(원격에서 두 시점을 모두 재고 원격 시계로 나눈다). **테스트망에서만 실행**
- `mf_gwguard.sh` (`test-results/2026-08-02-50mbps-soak/`) — **부하 감시·차단. 모든 부하 하네스가 이걸 쓴다.** 2026-08-05 재작성: gw 대역폭 대리지표 → **호스트 CPU·최고1코어·링크** 직접 측정(위 규칙 0 표). `precheck`(전제 검증) · `sample` · `budget`(용량 모델) · `watch`(트립 시 부하 중단). 이름은 역사적 — 호출부가 전부 이 이름을 쓴다. **테스트망에서만 실행**
- `mf_sampler3.sh` (`test-results/2026-08-02-50mbps-soak/`) — 자원 샘플러 v3. v2 의 프로세스 CPU/RSS/FD/iface/netem 에 더해 **시스템 전체 per-CPU** 를 `<out>_cpu.csv` 사이드카로 남긴다(`/proc/stat` 델타, mpstat 과 동일 항목·수식). v2 는 프로세스 하나만 봐서 softirq·WG·부하생성기를 포함한 머신 총량을 알 수 없었다. **주의**: 프로세스 `cpu_pct` 는 논리 CPU 1개=100% 기준이고 사이드카는 코어별 100% 기준이라 스케일이 다르다. **테스트망에서만 실행**
- `test_all_options.py` — 전체 CLI 옵션 90개 케이스
- `test_perf_stability.py` — 성능·안정성 26개 케이스
- `test_rnlc_unit.cpp` — RNLC 인코드/디코드 결정적 유닛 테스트 11개 케이스 (`make test-rnlc-unit`)
- `test_rnlc.py` — RNLC end-to-end 통합 검증 9개 케이스
- `test_scale_sessions.py` — 다중 세션(session_id) 부하/스케일 + 아징 소크 테스트 (루프백 단일 호스트). 세션 수를 늘리며 서버 RSS/CPU/처리량/세션 간 cross-talk 측정. `--aging N`으로 장시간 소크(주기 샘플링·누수/크래시/cross-talk 감지). 1프로세스=1세션.
- `aging_rt_server.py` / `aging_rt_clients.py` — 실제 토폴로지(c→r→s) 다중 세션 아징 하베스트. 서버+sink(s측), 클라이언트 N개+태그 생성기(c측)로 분리. 평행 테스트 체인(:4443)으로 운영(:443) 비침습. 10세션 3h 검증 완료(누수0·crosstalk0·전달99.85%).

> 다운스트림 FEC 측정은 합성 왕복으로 불가(양방향 mud/FEC 결합으로 신호 묻힘). 실제 WG `starlink-fec` 터널(s=10.9.10.1, c=10.9.10.2) 위 `iperf3 -R`로 측정. 실측: mode1 다운 12.0Mbps/잔여손실0.006%, mode2(RNLC) 2.93Mbps/0.68% (netem 15%, fec 20:5).

**참고 문서:**
- `DEPLOY_EXAMPLES.md` — 10가지 배포 시나리오별 전체 설정 예제
