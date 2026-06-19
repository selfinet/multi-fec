# multi-fec — 개발자 레퍼런스

## 작업 워크플로 (Claude)

- Claude가 생성한 PR은 별도 확인 없이 `dev` 브랜치로 **자동 머지**한다 (머지 방식: merge 커밋).
- 자동 머지 후 결과(머지 커밋 SHA)를 보고한다. CI가 구성되어 있으면 통과 확인 후 머지한다.

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
- `DEGRADED`: RTT 초과
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
| `-k keystring` | 문자열 최대 999자 | `"default-key"` | PSK. 릴레이는 선택(없으면 투명 중계) |
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

### 릴레이 전용

| 옵션 | 값 범위 | 기본값 | 설명 |
|------|---------|--------|------|
| `--upstream ip:port` | — | — | 단일 upstream 서버 주소 (단일 모드 필수) |
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
| `--decode-buf N` | `300`–`20000` | `2000` | FEC 디코더 링버퍼 크기 |
| `--disable-fec` | — | 비활성 | FEC 완전 비활성화 (passthrough) |

**FEC x:y 내부 파라미터**: 그룹 크기 1~x에 대해 복구 비율 y 적용.
예: `10:3` → 데이터 1~10패킷 + 복구 3패킷/그룹.

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
| `MUD_PATH_MAX` | `8` | 최대 경로 수 |

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
make clean             # 클린
```

의존성: gcc/g++ (C11/C++11), libev (bundled in `libev/`), librt, libpthread

### 빌드 타겟 비교

| 타겟 | 결과물 | 크기 | 용도 |
|------|--------|------|------|
| `make` | `multi-fec` | 279 KB | 개발/테스트 |
| `make static` | `multi-fec-static` | 1.5 MB | 정적 빌드 (심볼 포함) |
| `make static-strip` | `multi-fec-dist` | 1.3 MB | 배포용 (권장) |

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
  --decode-buf 8000 \
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
  --decode-buf 8000 \
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
| `--decode-buf 8000` | 2000→8000 | 높은 지터로 패킷이 늦게 도착해도 FEC 그룹 유지 가능 |
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
세부 분석: `test-results/2026-06-19-multi-session/downstream-fec/rnlc-decode-bottleneck-analysis.md`.

---

**테스트 스크립트:**
- `test_relay_routing.py` — 릴레이 키별 라우팅 7개 케이스
- `test_all_options.py` — 전체 CLI 옵션 90개 케이스
- `test_perf_stability.py` — 성능·안정성 26개 케이스
- `test_rnlc_unit.cpp` — RNLC 인코드/디코드 결정적 유닛 테스트 11개 케이스 (`make test-rnlc-unit`)
- `test_rnlc.py` — RNLC end-to-end 통합 검증 9개 케이스
- `test_scale_sessions.py` — 다중 세션(session_id) 부하/스케일 + 아징 소크 테스트 (루프백 단일 호스트). 세션 수를 늘리며 서버 RSS/CPU/처리량/세션 간 cross-talk 측정. `--aging N`으로 장시간 소크(주기 샘플링·누수/크래시/cross-talk 감지). 1프로세스=1세션.
- `aging_rt_server.py` / `aging_rt_clients.py` — 실제 토폴로지(c→r→s) 다중 세션 아징 하베스트. 서버+sink(s측), 클라이언트 N개+태그 생성기(c측)로 분리. 평행 테스트 체인(:4443)으로 운영(:443) 비침습. 10세션 3h 검증 완료(누수0·crosstalk0·전달99.85%).

> 다운스트림 FEC 측정은 합성 왕복으로 불가(양방향 mud/FEC 결합으로 신호 묻힘). 실제 WG `starlink-fec` 터널(s=10.9.10.1, c=10.9.10.2) 위 `iperf3 -R`로 측정. 실측: mode1 다운 12.0Mbps/잔여손실0.006%, mode2(RNLC) 2.93Mbps/0.68% (netem 15%, fec 20:5).

**참고 문서:**
- `DEPLOY_EXAMPLES.md` — 10가지 배포 시나리오별 전체 설정 예제
