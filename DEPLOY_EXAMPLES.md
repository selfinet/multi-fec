# multi-fec 배포 시나리오 레퍼런스

각 시나리오는 독립적으로 완성된 설정을 제공한다. IP 주소와 포트는 예시이며 실제 환경에 맞게 교체한다.

---

## 공통 전제

- 바이너리: `/usr/local/bin/multi-fec` (정적 빌드 권장: `make static-strip`)
- 환경변수 파일: `/etc/multi-fec/*.conf`
- 런타임 소켓: `/run/multi-fec/*.fifo`
- WireGuard MTU: 단일 경로 또는 obfs 없는 구간은 1380, obfs 활성화 구간은 1300 (단편화 방지)
- `TimeoutStopSec=3`: SIGTERM 핸들러 없어 기본 90초 대기가 발생하므로 모든 서비스에 적용

---

## 시나리오 1 — 기본 설정 (국내, 안정 링크, 단일 경로)

**대상**: 국내 두 서버 간 WireGuard 터널 안정성 보강. 손실 거의 없고 RTT 5ms 이하.  
FEC는 최소 오버헤드로 유지하고 obfs는 활성화해 DPI 우회를 기본으로 적용.

```
[WG 클라이언트 :51820]
        │
[multi-fec 클라이언트 192.168.1.10]
        │ UDP :443 (QUIC obfs)
[multi-fec 서버 1.2.3.4]
        │
[WG 서버 :51820]
```

### WireGuard MTU

```ini
# 클라이언트·서버 양쪽 /etc/wireguard/wg0.conf
[Interface]
MTU = 1380
```

obfs QUIC 헤더 10B + mud 헤더 ~32B = ~42B 오버헤드.
이더넷 MTU 1500 기준 여유: 1500 - 42 = 1458B > WG 패킷 1380B.

### 서버

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k "my-domestic-key" \
  --obfs-mode quic \
  -f 20:2 \
  --mode 0 \
  --fec-timeout 8 \
  --mtu 1380 \
  --report 60 \
  --log-level 4 \
  --fifo /run/multi-fec/server.fifo
```

### 클라이언트

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:1.2.3.4:443 \
  -k "my-domestic-key" \
  --obfs-mode quic \
  --multipath-mode failover \
  -f 20:2 \
  --mode 0 \
  --fec-timeout 8 \
  --mtu 1380 \
  --report 60 \
  --log-level 4 \
  --fifo /run/multi-fec/client.fifo
```

### 옵션 선택 이유

- `-f 20:2` (오버헤드 10%): 국내 안정 링크에서 패킷 손실은 드물므로 복구 패킷 최소화.
- `--fec-timeout 8` 기본값: RTT 5ms 환경에서 8ms flush는 충분히 짧아 지연 영향 없음.

### systemd — 서버

`/etc/multi-fec/server.conf`:
```bash
LISTEN=0.0.0.0:443
WG=127.0.0.1:51820
KEY=my-domestic-key
OBFS_MODE=quic
FEC=20:2
FEC_MODE=0
FEC_TIMEOUT=8
MTU=1380
REPORT=60
LOG_LEVEL=4
```

`/etc/systemd/system/multi-fec-server.service`:
```ini
[Unit]
Description=multi-fec server
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/server.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -s \
    -l ${LISTEN} --wg ${WG} -k ${KEY} \
    --obfs-mode ${OBFS_MODE} -f ${FEC} \
    --mode ${FEC_MODE} --fec-timeout ${FEC_TIMEOUT} \
    --mtu ${MTU} --report ${REPORT} --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/server.fifo
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

### systemd — 클라이언트

`/etc/multi-fec/client.conf`:
```bash
LISTEN=127.0.0.1:51820
SERVER=1.2.3.4
KEY=my-domestic-key
OBFS_MODE=quic
FEC=20:2
FEC_MODE=0
FEC_TIMEOUT=8
MTU=1380
REPORT=60
LOG_LEVEL=4
```

`/etc/systemd/system/multi-fec-client.service`:
```ini
[Unit]
Description=multi-fec client
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/client.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -c \
    -l ${LISTEN} \
    --path 0.0.0.0:${SERVER}:443 \
    -k ${KEY} --obfs-mode ${OBFS_MODE} \
    --multipath-mode failover \
    -f ${FEC} --mode ${FEC_MODE} --fec-timeout ${FEC_TIMEOUT} \
    --mtu ${MTU} --report ${REPORT} --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/client.fifo
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

---

## 시나리오 2 — 국제 구간 기본 (해외 서버, 단일 경로, FEC 중간)

**대상**: 한국 → 미국/일본 등 단일 해저케이블 경로. RTT 100~200ms, 손실 3~8%.

```
[WG 클라이언트 KR]
        │
[multi-fec 클라이언트 KR]
        │ UDP :443  RTT ~150ms  손실 ~5%
[multi-fec 서버 US]
        │
[WG 서버 US]
```

### WireGuard MTU

```ini
[Interface]
MTU = 1300
```

obfs TLS 헤더 14B + mud 헤더 ~32B + 여유 = ~50B. 1300 + 50 = 1350B < 1472B (PPPoE 경로 PMTU).

### 서버 (US)

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k "intl-key-01" \
  --obfs-mode quic \
  --auth-interval 60 \
  -f 20:4 \
  --mode 0 \
  --fec-timeout 20 \
  --mtu 1250 \
  --decode-buf 4000 \
  --queue-len 300 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/server.fifo
```

### 클라이언트 (KR)

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:203.0.113.10:443 \
  -k "intl-key-01" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode failover \
  -f 20:4 \
  --mode 0 \
  --fec-timeout 20 \
  --mtu 1250 \
  --decode-buf 4000 \
  --queue-len 300 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/client.fifo
```

### 옵션 선택 이유

- `-f 20:4` (오버헤드 20%): 5% 손실 시 FEC 그룹당 최대 ~16% 손실까지 복구 가능.
- `--fec-timeout 20`: RTT 150ms 환경에서 8ms flush는 그룹이 조기 종료되어 FEC 효율 저하. 20ms로 그룹 완성 대기.
- `--decode-buf 4000`: 높은 지터 환경에서 늦게 도착하는 FEC 그룹을 링버퍼에 유지.
- `--sock-buf 4096`: BDP = 150ms × 10Mbps ≈ 187KB. 커널 기본 버퍼(~212KB)가 부족한 고대역 구간 대비.
- `--auth-interval 60`: HMAC 슬롯 길이를 60초로 늘려 슬롯 경계 시각 통계 분석 탐지를 어렵게 함.

### systemd 서비스 파일 (클라이언트, 서버 동일 구조)

`/etc/multi-fec/client-intl.conf`:
```bash
LISTEN=127.0.0.1:51820
SERVER=203.0.113.10
KEY=intl-key-01
OBFS_MODE=quic
AUTH_INTERVAL=60
FEC=20:4
FEC_MODE=0
FEC_TIMEOUT=20
MTU=1250
DECODE_BUF=4000
QUEUE_LEN=300
SOCK_BUF=4096
REPORT=30
LOG_LEVEL=4
```

`/etc/systemd/system/multi-fec-client.service`:
```ini
[Unit]
Description=multi-fec client (international)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/client-intl.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -c \
    -l ${LISTEN} \
    --path 0.0.0.0:${SERVER}:443 \
    -k ${KEY} --obfs-mode ${OBFS_MODE} \
    --auth-interval ${AUTH_INTERVAL} \
    --multipath-mode failover \
    -f ${FEC} --mode ${FEC_MODE} --fec-timeout ${FEC_TIMEOUT} \
    --mtu ${MTU} --decode-buf ${DECODE_BUF} \
    --queue-len ${QUEUE_LEN} --sock-buf ${SOCK_BUF} \
    --report ${REPORT} --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/client.fifo
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

---

## 시나리오 3 — 국제 구간 + 2개 릴레이 집계 (aggregate, 대역폭 합산)

**대상**: 클라이언트/서버 각 1회선이지만 릴레이 2개가 서로 다른 해저케이블을 사용.  
`aggregate` 모드로 두 케이블의 처리량을 실질적으로 합산.

```
[WG 클라이언트 KR]
        │
[multi-fec 클라이언트 KR] ──path1──▶ [릴레이1 HK, 케이블 A, :443] ──▶ [multi-fec 서버 US]
                           ──path2──▶ [릴레이2 JP, 케이블 B, :443] ──▶         │
                                                                          [WG 서버 US]

mud_lite 가중 분배:
  케이블 A 실효 8Mbps  → 전체의 40% 패킷 담당
  케이블 B 실효 12Mbps → 전체의 60% 패킷 담당
  서버 수신 합산: ~20Mbps (단일 12Mbps 대비 ~67% 향상)
```

### WireGuard MTU

```ini
[Interface]
MTU = 1300
```

### 서버 (US)

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k "agg-key-2024" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode aggregate \
  -f 20:4 \
  --mode 0 \
  --fec-timeout 20 \
  --mtu 1250 \
  --decode-buf 8000 \
  --queue-len 500 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/server.fifo
```

### 릴레이1 (HK, 케이블 A)

```bash
multi-fec -r \
  -l 0.0.0.0:443 \
  --upstream 203.0.113.10:443 \
  -k "agg-key-2024" \
  --obfs-mode quic \
  --sock-buf 4096 \
  --log-level 4
```

### 릴레이2 (JP, 케이블 B)

릴레이1과 완전히 동일한 명령. 릴레이는 FEC를 처리하지 않고 raw bytes를 투명하게 통과시키므로
추가 설정 없이 복제 사용 가능.

```bash
multi-fec -r \
  -l 0.0.0.0:443 \
  --upstream 203.0.113.10:443 \
  -k "agg-key-2024" \
  --obfs-mode quic \
  --sock-buf 4096 \
  --log-level 4
```

### 클라이언트 (KR)

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:relay1-hk-ip:443 \
  --path 0.0.0.0:relay2-jp-ip:443 \
  -k "agg-key-2024" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode aggregate \
  -f 20:4 \
  --mode 0 \
  --fec-timeout 20 \
  --mtu 1250 \
  --decode-buf 8000 \
  --queue-len 500 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/client.fifo
```

### 옵션 선택 이유

- `--multipath-mode aggregate`: mud_lite가 tx.rate 비례 가중 라운드로빈으로 경로별 다른 패킷을 분배. 두 케이블의 처리량이 실제로 합산된다.
- `--decode-buf 8000`: 두 경로의 RTT가 다를 때(홍콩 120ms, 도쿄 80ms) 늦게 도착하는 그룹 유지. FEC 복구율 유지에 필수.

### systemd — 릴레이 (HK/JP 공통)

`/etc/multi-fec/relay.conf`:
```bash
LISTEN=0.0.0.0:443
UPSTREAM=203.0.113.10:443
KEY=agg-key-2024
OBFS_MODE=quic
SOCK_BUF=4096
LOG_LEVEL=4
```

`/etc/systemd/system/multi-fec-relay.service`:
```ini
[Unit]
Description=multi-fec relay/POP
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/relay.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -r \
    -l ${LISTEN} --upstream ${UPSTREAM} \
    -k ${KEY} --obfs-mode ${OBFS_MODE} \
    --sock-buf ${SOCK_BUF} --log-level ${LOG_LEVEL}
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

### 주의: 클라이언트 멀티 인터페이스

두 경로의 소스 IP가 서로 다른 물리 인터페이스라면 policy routing이 필수다.

```bash
# 확인
ip route get relay1-hk-ip from 소스IP-1
ip route get relay2-jp-ip from 소스IP-2

# 수정 (다른 인터페이스라면)
ip route add default via GW1 dev IF1 table 101
ip route add default via GW2 dev IF2 table 102
ip rule add from 소스IP-1 table 101 priority 100
ip rule add from 소스IP-2 table 102 priority 101
```

클라이언트 소스 IP로 `0.0.0.0`을 사용하면 두 경로 모두 동일 인터페이스로 나가므로  
물리적 대역폭 합산 효과가 없다. 서로 다른 소스 IP를 명시해야 한다.

---

## 시나리오 4 — GFW 우회 (obfs quic, auth-interval 60, decoy 포함)

**대상**: 중국 내 클라이언트 → 해외 서버. GFW 심층 패킷 검사 및 액티브 프로빙 우회.  
nginx/caddy를 decoy 서버로 활용해 프로브에 실제 QUIC 응답을 제공.

```
[WG 클라이언트 CN]
        │
[multi-fec 클라이언트 CN] ──UDP :443 QUIC obfs──▶ [multi-fec 서버 HK :443]
                                                          │ (정상 패킷)
                                                   [WG 서버 HK :51820]

GFW 액티브 프로빙 흐름:
[GFW 프로버] ──UDP :443──▶ [multi-fec 서버 HK] ──UDP :8443──▶ [nginx QUIC HK]
[GFW 프로버] ◀──────── QUIC 응답 ────── decoy_io_cb ◀──────────────────

nginx :443 TCP 직접 처리 (GFW TCP 프로브 대응)
nginx :8443 UDP = QUIC 응답 소스 (루프백 전용, 외부 비노출)
```

### WireGuard MTU

```ini
[Interface]
MTU = 1300
```

### 서버 (HK) — nginx decoy 구성 먼저

nginx는 `:443` TCP + `:8443` UDP(QUIC)를 서비스한다.  
multi-fec는 `:443` UDP를 점유하므로 nginx는 TCP `:443`만 바인딩.

```nginx
# /etc/nginx/sites-available/decoy
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    listen 8443 quic reuseport;
    listen [::]:8443 quic reuseport;

    server_name _;
    ssl_certificate     /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    add_header Alt-Svc 'h3=":443"; ma=86400';
    return 200 "OK";
}
```

### 서버 (HK) — multi-fec

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k "gfw-bypass-key-2024" \
  --obfs-mode quic \
  --auth-interval 60 \
  -f 20:4 \
  --mode 0 \
  --fec-timeout 20 \
  --mtu 1250 \
  --decode-buf 4000 \
  --queue-len 300 \
  --sock-buf 4096 \
  --decoy 127.0.0.1:8443 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/server.fifo
```

### 클라이언트 (CN)

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:hk-server-ip:443 \
  -k "gfw-bypass-key-2024" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode failover \
  -f 20:4 \
  --mode 0 \
  --fec-timeout 20 \
  --mtu 1250 \
  --decode-buf 4000 \
  --queue-len 300 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/client.fifo
```

### 옵션 선택 이유

- `--obfs-mode quic`: QUIC Long Header Initial 1200B 고정 크기 패킷으로 DPI가 QUIC로 분류. TLS 모드보다 GFW 통과율 높음.
- `--auth-interval 60`: HMAC 슬롯 경계가 60초 간격이므로, 통계적 슬롯 경계 탐지를 위한 관측 구간이 두 배로 늘어남.
- `--decoy 127.0.0.1:8443`: HMAC 실패(GFW 프로브) 패킷을 nginx QUIC로 포워딩해 실제 QUIC 서버처럼 응답. `--decoy` 미지정 시에도 내장 QUIC Server Initial(1200~1455B)로 자동 응답하지만, 실제 nginx 응답이 핑거프린팅 회피에 더 강력.

### systemd — 서버

`/etc/multi-fec/server-gfw.conf`:
```bash
LISTEN=0.0.0.0:443
WG=127.0.0.1:51820
KEY=gfw-bypass-key-2024
OBFS_MODE=quic
AUTH_INTERVAL=60
FEC=20:4
FEC_MODE=0
FEC_TIMEOUT=20
MTU=1250
DECODE_BUF=4000
QUEUE_LEN=300
SOCK_BUF=4096
DECOY=127.0.0.1:8443
REPORT=30
LOG_LEVEL=4
```

`/etc/systemd/system/multi-fec-server.service`:
```ini
[Unit]
Description=multi-fec server (GFW bypass)
After=network.target nginx.service

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/server-gfw.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -s \
    -l ${LISTEN} --wg ${WG} -k ${KEY} \
    --obfs-mode ${OBFS_MODE} --auth-interval ${AUTH_INTERVAL} \
    -f ${FEC} --mode ${FEC_MODE} --fec-timeout ${FEC_TIMEOUT} \
    --mtu ${MTU} --decode-buf ${DECODE_BUF} \
    --queue-len ${QUEUE_LEN} --sock-buf ${SOCK_BUF} \
    --decoy ${DECOY} \
    --report ${REPORT} --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/server.fifo
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

---

## 시나리오 5 — 고가용성 (duplicate 모드, 2경로 동시)

**대상**: 중단 없는 서비스가 최우선. 두 ISP 경로를 동시에 사용해 한쪽이 단절되어도 즉시 대응.  
처리량은 단일 경로 수준이지만 가용성이 최고.

```
[WG 클라이언트]
        │
[multi-fec 클라이언트]
        ├── path1 ──▶ [ISP A, 10.0.0.1] ──▶ [multi-fec 서버]
        └── path2 ──▶ [ISP B, 10.0.1.1] ──▶         │
                                              [WG 서버]

동일 패킷이 양쪽 경로에 전송됨 (duplicate)
서버 수신 측: MUD_DEDUP_SIZE=128 링버퍼로 중복 제거 (TTL 500ms)
ISP A 단절 시 → ISP B만으로 즉시 계속 동작 (0ms 절체)
```

### WireGuard MTU

```ini
[Interface]
MTU = 1300
```

### 서버

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k "ha-key-2024" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode duplicate \
  -f 20:2 \
  --mode 0 \
  --fec-timeout 10 \
  --mtu 1250 \
  --decode-buf 2000 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/server.fifo
```

### 클라이언트

클라이언트 장비에 ISP A(eth0, 10.0.0.1/24)와 ISP B(eth1, 10.0.1.1/24)가 연결되어 있다고 가정.

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 10.0.0.1:203.0.113.10:443 \
  --path 10.0.1.1:203.0.113.10:443 \
  -k "ha-key-2024" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode duplicate \
  -f 20:2 \
  --mode 0 \
  --fec-timeout 10 \
  --mtu 1250 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/client.fifo
```

### policy routing 설정 (클라이언트)

두 소스 IP가 서로 다른 게이트웨이를 사용해야 한다.

```bash
# /etc/network/policy-routing.sh
ip route add default via 10.0.0.254 dev eth0 table 101
ip route add default via 10.0.1.254 dev eth1 table 102
ip rule add from 10.0.0.1 table 101 priority 100
ip rule add from 10.0.1.1 table 102 priority 101
```

`/etc/systemd/system/policy-routing.service`:
```ini
[Unit]
Description=Policy routing for multi-fec dual ISP
After=network.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash /etc/network/policy-routing.sh

[Install]
WantedBy=multi-user.target
```

### 옵션 선택 이유

- `--multipath-mode duplicate`: 동일 패킷을 두 경로에 전송하여 한쪽 경로 단절 시 전환 지연 없이 계속 동작. mud_lite dedup이 중복 패킷을 500ms TTL 내에 제거.
- `-f 20:2` (오버헤드 10%): duplicate 모드는 이미 경로 이중화로 신뢰성을 확보하므로 FEC는 최소 수준으로 유지.

### systemd — 클라이언트

`/etc/multi-fec/client-ha.conf`:
```bash
LISTEN=127.0.0.1:51820
SERVER=203.0.113.10
SRC_A=10.0.0.1
SRC_B=10.0.1.1
KEY=ha-key-2024
OBFS_MODE=quic
AUTH_INTERVAL=60
FEC=20:2
FEC_MODE=0
FEC_TIMEOUT=10
MTU=1250
SOCK_BUF=4096
REPORT=30
LOG_LEVEL=4
```

`/etc/systemd/system/multi-fec-client.service`:
```ini
[Unit]
Description=multi-fec client (high availability)
After=network.target policy-routing.service

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/client-ha.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -c \
    -l ${LISTEN} \
    --path ${SRC_A}:${SERVER}:443 \
    --path ${SRC_B}:${SERVER}:443 \
    -k ${KEY} --obfs-mode ${OBFS_MODE} \
    --auth-interval ${AUTH_INTERVAL} \
    --multipath-mode duplicate \
    -f ${FEC} --mode ${FEC_MODE} --fec-timeout ${FEC_TIMEOUT} \
    --mtu ${MTU} --sock-buf ${SOCK_BUF} \
    --report ${REPORT} --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/client.fifo
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

---

## 시나리오 6 — aggregate-duplicate 혼합 (3경로, dup-factor 2, 집계+이중화)

**대상**: ISP 3개를 보유한 환경. 처리량 합산과 이중화를 동시에 추구.  
각 패킷이 3개 경로 중 tx.rate 기반 상위 2개 경로에 전송됨.

```
[WG 클라이언트]
        │
[multi-fec 클라이언트]
        ├── path1 (ISP-A, 100Mbps) ──▶
        ├── path2 (ISP-B,  50Mbps) ──▶  [multi-fec 서버]
        └── path3 (ISP-C,  50Mbps) ──▶         │
                                         [WG 서버]

dup-factor 2: 각 패킷 → 상위 2개 경로 동시 전송
가중 분배:
  ISP-A credit += 100 → 선택 횟수 2배 (전체 ~50%)
  ISP-B credit +=  50 → (전체 ~25%)
  ISP-C credit +=  50 → (전체 ~25%)
  서버 합산 처리량: ~150Mbps 중 경로 중복 제거 후 실효 ~100~120Mbps
한 경로 단절: 나머지 2경로로 dup-factor 2 계속 유지 → 무중단
```

### WireGuard MTU

```ini
[Interface]
MTU = 1300
```

### 서버

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k "agg-dup-key" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode aggregate-duplicate \
  -f 20:3 \
  --mode 0 \
  --fec-timeout 15 \
  --mtu 1250 \
  --decode-buf 8000 \
  --queue-len 500 \
  --sock-buf 8192 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/server.fifo
```

### 클라이언트

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 192.168.1.1:203.0.113.10:443 \
  --path 192.168.2.1:203.0.113.10:443 \
  --path 192.168.3.1:203.0.113.10:443 \
  -k "agg-dup-key" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode aggregate-duplicate \
  --dup-factor 2 \
  -f 20:3 \
  --mode 0 \
  --fec-timeout 15 \
  --mtu 1250 \
  --decode-buf 8000 \
  --queue-len 500 \
  --sock-buf 8192 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/client.fifo
```

### 옵션 선택 이유

- `--multipath-mode aggregate-duplicate --dup-factor 2`: 3개 경로 중 tx.rate 상위 2개에 동일 패킷 전송. 한 경로가 LOSSY/단절되어도 나머지 2개로 dup-factor 2가 유지된다.
- `-f 20:3` (오버헤드 15%): aggregate 경로 분배 특성상 단일 경로보다 손실이 덜하므로 duplicate 시나리오보다 복구 패킷을 조금 더 추가.

### systemd — 클라이언트

`/etc/multi-fec/client-aggdup.conf`:
```bash
LISTEN=127.0.0.1:51820
SERVER=203.0.113.10
SRC_A=192.168.1.1
SRC_B=192.168.2.1
SRC_C=192.168.3.1
KEY=agg-dup-key
OBFS_MODE=quic
AUTH_INTERVAL=60
FEC=20:3
FEC_MODE=0
FEC_TIMEOUT=15
MTU=1250
DECODE_BUF=8000
QUEUE_LEN=500
SOCK_BUF=8192
REPORT=30
LOG_LEVEL=4
```

`/etc/systemd/system/multi-fec-client.service`:
```ini
[Unit]
Description=multi-fec client (aggregate-duplicate 3-path)
After=network.target policy-routing.service

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/client-aggdup.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -c \
    -l ${LISTEN} \
    --path ${SRC_A}:${SERVER}:443 \
    --path ${SRC_B}:${SERVER}:443 \
    --path ${SRC_C}:${SERVER}:443 \
    -k ${KEY} --obfs-mode ${OBFS_MODE} \
    --auth-interval ${AUTH_INTERVAL} \
    --multipath-mode aggregate-duplicate \
    --dup-factor 2 \
    -f ${FEC} --mode ${FEC_MODE} --fec-timeout ${FEC_TIMEOUT} \
    --mtu ${MTU} --decode-buf ${DECODE_BUF} \
    --queue-len ${QUEUE_LEN} --sock-buf ${SOCK_BUF} \
    --report ${REPORT} --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/client.fifo
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

---

## 시나리오 7 — 저손실 최고속도 (FEC 최소화 또는 비활성)

**대상**: 데이터센터 간 전용선 또는 손실 0~0.5% 이하 구간. FEC 오버헤드 없이 원시 처리량 극대화.

```
[WG 클라이언트 DC-A]
        │
[multi-fec 클라이언트] ──10GbE 전용선, RTT 1ms──▶ [multi-fec 서버 DC-B]
                                                          │
                                                   [WG 서버 DC-B]
```

### WireGuard MTU

```ini
[Interface]
MTU = 1420
```

obfs 비활성화 시 헤더 오버헤드 최소. mud 헤더만 ~32B 추가 → 1420 + 32 = 1452B < 1500B.

### 방법 A — FEC 최소화 (--disable-fec 없이 최소 비율)

손실이 가끔 발생하는 경우 FEC 완전 비활성화 대신 최소 비율로 유지한다.

```bash
# 서버
multi-fec -s \
  -l 0.0.0.0:9000 \
  --wg 127.0.0.1:51820 \
  -k "dc-link-key" \
  --disable-obfs \
  -f 20:1 \
  --mode 0 \
  --fec-timeout 5 \
  --mtu 1420 \
  --sock-buf 8192 \
  --report 60 \
  --log-level 3

# 클라이언트
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:10.0.0.2:9000 \
  -k "dc-link-key" \
  --disable-obfs \
  --multipath-mode failover \
  -f 20:1 \
  --mode 0 \
  --fec-timeout 5 \
  --mtu 1420 \
  --sock-buf 8192 \
  --report 60 \
  --log-level 3
```

### 방법 B — FEC 완전 비활성화

손실이 사실상 없는 구간에서 FEC 연산 오버헤드마저 제거.

```bash
# 서버
multi-fec -s \
  -l 0.0.0.0:9000 \
  --wg 127.0.0.1:51820 \
  -k "dc-link-key" \
  --disable-obfs \
  --disable-fec \
  --mtu 1420 \
  --sock-buf 8192 \
  --report 60 \
  --log-level 3

# 클라이언트
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:10.0.0.2:9000 \
  -k "dc-link-key" \
  --disable-obfs \
  --disable-fec \
  --multipath-mode failover \
  --mtu 1420 \
  --sock-buf 8192 \
  --report 60 \
  --log-level 3
```

### 옵션 선택 이유

- `--disable-obfs`: 전용선 환경에서 DPI 우회가 불필요하므로 obfs 헤더 오버헤드(10~14B) 제거.
- `-f 20:1` 또는 `--disable-fec`: 손실 0~0.5% 구간에서 FEC 복구 패킷(5~100% 오버헤드)의 비용 대비 효과 없음.
- `--sock-buf 8192` (8MB): 10GbE 고대역에서 BDP가 크므로 커널 소켓 버퍼를 넓게 설정.

### systemd — 서버 (방법 B)

`/etc/multi-fec/server-fast.conf`:
```bash
LISTEN=0.0.0.0:9000
WG=127.0.0.1:51820
KEY=dc-link-key
MTU=1420
SOCK_BUF=8192
REPORT=60
LOG_LEVEL=3
```

`/etc/systemd/system/multi-fec-server.service`:
```ini
[Unit]
Description=multi-fec server (high speed, no FEC)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/server-fast.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -s \
    -l ${LISTEN} --wg ${WG} -k ${KEY} \
    --disable-obfs --disable-fec \
    --mtu ${MTU} --sock-buf ${SOCK_BUF} \
    --report ${REPORT} --log-level ${LOG_LEVEL}
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

---

## 시나리오 8 — 고손실 링크 (FEC 강화, decode-buf 확대)

**대상**: Starlink, 저궤도 위성, 4G/5G 백홀 등 손실 10~25% + 지터 50~200ms 환경.

```
[WG 클라이언트]
        │
[multi-fec 클라이언트] ──위성/LTE, 손실 15%, 지터 100ms──▶ [multi-fec 서버]
                                                                    │
                                                             [WG 서버]
```

### WireGuard MTU

```ini
[Interface]
MTU = 1280
```

위성 경로는 실질적 PMTU가 낮은 경우가 있으므로 여유 있게 설정.

### 서버

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k "satellite-key" \
  --obfs-mode quic \
  --auth-interval 60 \
  -f 20:7 \
  --mode 0 \
  --fec-timeout 30 \
  --mtu 1200 \
  --decode-buf 12000 \
  --queue-len 600 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/server.fifo
```

### 클라이언트

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:203.0.113.10:443 \
  -k "satellite-key" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode failover \
  -f 20:7 \
  --mode 0 \
  --fec-timeout 30 \
  --mtu 1200 \
  --decode-buf 12000 \
  --queue-len 600 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/client.fifo
```

### 옵션 선택 이유

- `-f 20:7` (오버헤드 35%): 최대 ~25% 손실까지 FEC 복구. 15% 평균 손실에 버스트 대비 여유 포함.
- `--fec-timeout 30`: 지터 100ms 환경에서 30ms flush는 빠른 축. 200ms 지터라면 50~80ms로 늘린다.
- `--decode-buf 12000`: 지터 100ms + RTT 600ms(위성) 환경에서 FEC 그룹이 순서를 벗어나 수백ms 후 도착 가능. 링버퍼가 작으면 그룹이 제거되어 FEC 복구 불가.

### FEC 비율 조정 가이드 (FIFO 런타임)

손실률이 변동하는 환경에서 재시작 없이 FEC를 조정한다.

```bash
# 현재 손실 5%로 호전 → FEC 완화
echo "fec 20:4" > /run/multi-fec/client.fifo

# 현재 손실 20%로 악화 → FEC 강화
echo "fec 20:8" > /run/multi-fec/client.fifo

# 현재 설정 확인 (report 주기로 로그 확인)
journalctl -u multi-fec-client -f
```

### systemd — 클라이언트

`/etc/multi-fec/client-satellite.conf`:
```bash
LISTEN=127.0.0.1:51820
SERVER=203.0.113.10
KEY=satellite-key
OBFS_MODE=quic
AUTH_INTERVAL=60
FEC=20:7
FEC_MODE=0
FEC_TIMEOUT=30
MTU=1200
DECODE_BUF=12000
QUEUE_LEN=600
SOCK_BUF=4096
REPORT=30
LOG_LEVEL=4
```

`/etc/systemd/system/multi-fec-client.service`:
```ini
[Unit]
Description=multi-fec client (high-loss satellite/LTE)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/client-satellite.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -c \
    -l ${LISTEN} \
    --path 0.0.0.0:${SERVER}:443 \
    -k ${KEY} --obfs-mode ${OBFS_MODE} \
    --auth-interval ${AUTH_INTERVAL} \
    --multipath-mode failover \
    -f ${FEC} --mode ${FEC_MODE} --fec-timeout ${FEC_TIMEOUT} \
    --mtu ${MTU} --decode-buf ${DECODE_BUF} \
    --queue-len ${QUEUE_LEN} --sock-buf ${SOCK_BUF} \
    --report ${REPORT} --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/client.fifo
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

---

## 시나리오 9 — 릴레이 키별 라우팅 (여러 서버를 하나의 릴레이로)

**대상**: 단일 POP(릴레이)가 두 조직의 서버로 트래픽을 분기. 키가 다른 클라이언트를 각각 다른 upstream으로 전달.

```
[클라이언트 팀A, key=keyA] ──▶
                              [릴레이 POP :443] ──key A 매칭──▶ [서버 A 1.2.3.4:443]
[클라이언트 팀B, key=keyB] ──▶
                              [릴레이 POP :443] ──key B 매칭──▶ [서버 B 5.6.7.8:443]

[GFW 프로버 / 불명 클라이언트] ──▶
                              [릴레이 POP :443] ──매칭 없음──▶ 내장 QUIC Server Initial
                                                               (nginx 불필요)
```

### 서버 A (팀A 전용)

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k "keyA" \
  --obfs-mode quic \
  --auth-interval 60 \
  -f 20:4 \
  --mode 0 \
  --fec-timeout 20 \
  --mtu 1250 \
  --decode-buf 4000 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/server-a.fifo
```

### 서버 B (팀B 전용)

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k "keyB" \
  --obfs-mode quic \
  --auth-interval 60 \
  -f 20:4 \
  --mode 0 \
  --fec-timeout 20 \
  --mtu 1250 \
  --decode-buf 4000 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/server-b.fifo
```

### 릴레이 — 키별 라우팅

`--route` 옵션을 반복해 키별 upstream을 지정한다. `-k` / `--upstream`과 혼용 불가.  
매칭 실패 패킷은 내장 QUIC Server Initial(1200~1455B)로 자동 응답 (`--decoy` 미지정 시).

```bash
multi-fec -r \
  -l 0.0.0.0:443 \
  --route "keyA 1.2.3.4:443" \
  --route "keyB 5.6.7.8:443" \
  --obfs-mode quic \
  --sock-buf 4096 \
  --log-level 4
```

decoy 서버(nginx)를 보유한 경우 `--decoy 127.0.0.1:8443` 추가.

### 클라이언트 A (팀A)

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:pop-relay-ip:443 \
  -k "keyA" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode failover \
  -f 20:4 \
  --mode 0 \
  --fec-timeout 20 \
  --mtu 1250 \
  --decode-buf 4000 \
  --sock-buf 4096 \
  --report 30 \
  --log-level 4
```

### 클라이언트 B (팀B)

클라이언트 A와 동일하되 `-k "keyB"` 변경.

### 옵션 선택 이유

- `--route` 반복 사용: 단일 POP에서 완전히 독립된 HMAC 컨텍스트로 각 키를 검증. 키 A를 가진 클라이언트가 서버 B에 접근할 수 없다.
- `--decoy` 미지정: 내장 QUIC Server Initial이 자동으로 응답하므로 nginx 없이도 GFW 프로빙을 처리 가능.

### systemd — 릴레이 (키별 라우팅)

`/etc/multi-fec/relay-route.conf`:
```bash
LISTEN=0.0.0.0:443
KEY_A=keyA
UPSTREAM_A=1.2.3.4:443
KEY_B=keyB
UPSTREAM_B=5.6.7.8:443
OBFS_MODE=quic
SOCK_BUF=4096
LOG_LEVEL=4
# decoy 없으면 이 줄 주석 처리 → 내장 QUIC Initial로 자동 응답
# DECOY=127.0.0.1:8443
```

`/etc/systemd/system/multi-fec-relay.service`:
```ini
[Unit]
Description=multi-fec relay (key-based routing)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/relay-route.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -r \
    -l ${LISTEN} \
    --route "${KEY_A} ${UPSTREAM_A}" \
    --route "${KEY_B} ${UPSTREAM_B}" \
    --obfs-mode ${OBFS_MODE} \
    --sock-buf ${SOCK_BUF} --log-level ${LOG_LEVEL}
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

```bash
systemctl daemon-reload
systemctl enable --now multi-fec-relay
journalctl -u multi-fec-relay -f
```

### 주의 사항

- 동일 (src_ip, src_port) 세션은 최초 키로 고정. 클라이언트 재시작 전까지 키 변경 불가.
- `--route` 테이블은 선언 순서대로 HMAC을 시도하므로 자주 접속하는 키를 앞에 배치하면 처리 효율이 소폭 향상된다 (SipHash 연산은 수십 ns 수준이라 실용적 차이는 없음).

---

## 시나리오 10 — 인터랙티브 트래픽 (게임/화상통화 저지연 최적화)

**대상**: 게임, VoIP, 화상통화 등 처리량보다 지연이 중요한 트래픽.  
FEC 그룹을 작게 유지해 첫 패킷부터 빠르게 전달하고, 큐잉 지연을 최소화.

```
[게임/VoIP 클라이언트] → [WG 클라이언트 :51820]
        │
[multi-fec 클라이언트] ──단일 경로, RTT 30ms──▶ [multi-fec 서버]
                                                        │
                                              [WG 서버] → [게임/VoIP 서버]
```

### WireGuard MTU

```ini
[Interface]
MTU = 1300
```

### 서버

```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k "game-key-2024" \
  --obfs-mode quic \
  --auth-interval 60 \
  -f 10:3 \
  --mode 1 \
  --fec-timeout 5 \
  --mtu 1250 \
  --decode-buf 2000 \
  --queue-len 100 \
  --sock-buf 2048 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/server.fifo
```

### 클라이언트

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:203.0.113.10:443 \
  -k "game-key-2024" \
  --obfs-mode quic \
  --auth-interval 60 \
  --multipath-mode failover \
  -f 10:3 \
  --mode 1 \
  --fec-timeout 5 \
  --mtu 1250 \
  --decode-buf 2000 \
  --queue-len 100 \
  --sock-buf 2048 \
  --report 30 \
  --log-level 4 \
  --fifo /run/multi-fec/client.fifo
```

### 옵션 선택 이유

- `--mode 1` (low-latency): 큐 없이 수신 즉시 전송. mode 0의 큐 기반 배칭 지연 제거. 인터랙티브 트래픽에 필수.
- `-f 10:3` (그룹 10패킷, 복구 3): 그룹이 작을수록 FEC 완성까지 대기하는 패킷 수가 적어 왕복 지연 최소화. `20:4` 대비 절반 크기.
- `--fec-timeout 5`: 5ms flush로 그룹을 즉시 전송. RTT 30ms 환경에서 충분히 짧음.
- `--queue-len 100`: mode 1에서는 큐 미사용이지만 버스트 보호용으로 최솟값 유지.

### mode 0과 mode 1 비교

| 항목 | mode 0 (bandwidth-saving) | mode 1 (low-latency) |
|------|---------------------------|----------------------|
| 큐 기반 배칭 | 있음 (`--queue-len`으로 제어) | 없음 (수신 즉시 전송) |
| FEC 효율 | 높음 (그룹을 꽉 채워 인코드) | 낮음 (그룹 미완성 시 조기 flush) |
| 첫 패킷 지연 | `--fec-timeout`만큼 추가 가능 | 최소 |
| 적합 트래픽 | 파일 전송, 스트리밍, 벌크 | 게임, VoIP, 화상통화 |

### systemd — 클라이언트

`/etc/multi-fec/client-game.conf`:
```bash
LISTEN=127.0.0.1:51820
SERVER=203.0.113.10
KEY=game-key-2024
OBFS_MODE=quic
AUTH_INTERVAL=60
FEC=10:3
FEC_MODE=1
FEC_TIMEOUT=5
MTU=1250
DECODE_BUF=2000
QUEUE_LEN=100
SOCK_BUF=2048
REPORT=30
LOG_LEVEL=4
```

`/etc/systemd/system/multi-fec-client.service`:
```ini
[Unit]
Description=multi-fec client (interactive/game)
After=network.target

[Service]
Type=simple
EnvironmentFile=/etc/multi-fec/client-game.conf
ExecStartPre=/bin/mkdir -p /run/multi-fec
ExecStart=/usr/local/bin/multi-fec -c \
    -l ${LISTEN} \
    --path 0.0.0.0:${SERVER}:443 \
    -k ${KEY} --obfs-mode ${OBFS_MODE} \
    --auth-interval ${AUTH_INTERVAL} \
    --multipath-mode failover \
    -f ${FEC} --mode ${FEC_MODE} --fec-timeout ${FEC_TIMEOUT} \
    --mtu ${MTU} --decode-buf ${DECODE_BUF} \
    --queue-len ${QUEUE_LEN} --sock-buf ${SOCK_BUF} \
    --report ${REPORT} --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/client.fifo
Restart=on-failure
RestartSec=5
TimeoutStopSec=3

[Install]
WantedBy=multi-user.target
```

---

## 시나리오별 설정 요약표

| # | 시나리오 | multipath-mode | FEC | --mode | fec-timeout | decode-buf | obfs | auth-interval |
|---|---------|----------------|-----|--------|-------------|------------|------|---------------|
| 1 | 국내 단일 경로 | failover | 20:2 | 0 | 8 | 2000 | quic | 30 |
| 2 | 국제 단일 경로 | failover | 20:4 | 0 | 20 | 4000 | quic | 60 |
| 3 | 국제 + 릴레이 2개 집계 | aggregate | 20:4 | 0 | 20 | 8000 | quic | 60 |
| 4 | GFW 우회 | failover | 20:4 | 0 | 20 | 4000 | quic + decoy | 60 |
| 5 | 고가용성 duplicate | duplicate | 20:2 | 0 | 10 | 2000 | quic | 60 |
| 6 | 3경로 집계+이중화 | aggregate-duplicate (dup=2) | 20:3 | 0 | 15 | 8000 | quic | 60 |
| 7 | 최고속도 저손실 | failover | 20:1 / disable | 0 | 5 | 2000 | disable | 30 |
| 8 | 고손실 위성/LTE | failover | 20:7 | 0 | 30 | 12000 | quic | 60 |
| 9 | 릴레이 키별 라우팅 | failover | 20:4 | 0 | 20 | 4000 | quic | 60 |
| 10 | 게임/화상통화 | failover | 10:3 | **1** | **5** | 2000 | quic | 60 |

---

## FEC 비율 선택 기준

링크 손실률을 모르는 경우 `--report 30`으로 30초마다 통계를 확인한 뒤 조정.

| 링크 상태 | 평균 손실률 | 권장 FEC | 오버헤드 | 최대 복구 |
|---------|-----------|---------|---------|---------|
| 안정적 | 0~3% | `-f 20:2` | 10% | 9% |
| 일반 국제선 | 3~8% | `-f 20:4` | 20% | 16% |
| 불안정 | 8~15% | `-f 20:7` | 35% | 25% |
| 위성/LTE | 15~25% | `-f 20:8` | 40% | 28% |

런타임 FEC 조정 (재시작 없이):
```bash
echo "fec 20:4"  > /run/multi-fec/client.fifo   # 클라이언트
echo "fec 20:4"  > /run/multi-fec/server.fifo   # 서버
echo "timeout 20" > /run/multi-fec/client.fifo  # fec-timeout 변경
```

---

## 공통 운영 명령

```bash
# 서비스 시작/중지/재시작
systemctl enable --now multi-fec-server
systemctl restart multi-fec-client
systemctl stop multi-fec-relay

# 실시간 로그 확인
journalctl -u multi-fec-server -f
journalctl -u multi-fec-client -f --since "5 min ago"

# 통계 리포트 강제 출력 (--report N 설정 필요)
kill -USR1 $(systemctl show -p MainPID --value multi-fec-client)

# 런타임 FEC 조정
echo "fec 20:6"    > /run/multi-fec/client.fifo
echo "timeout 25"  > /run/multi-fec/client.fifo
echo "mtu 1200"    > /run/multi-fec/client.fifo
echo "queue-len 400" > /run/multi-fec/client.fifo

# 진단: 패킷이 서버에 도달하는데 응답이 없을 때
# timetolerance 문제 가능성 (--log-level 5로 확인)
journalctl -u multi-fec-server --log-level 5 | grep "mud_recv=0"
```
