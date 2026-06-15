# multi-fec 사용 가이드

`multi-fec`는 WireGuard VPN 터널의 신뢰성을 높이는 UDP 프록시입니다.
FEC(전방 오류 정정), 다중 경로 전송, GFW/DPI 우회 난독화를 제공합니다.

---

## 빌드

### 일반 빌드 (동적 링크)

```bash
cd /home/stevekim/multi_udp/multi_fec
make -j$(nproc)
# 결과물: ./multi-fec (약 274 KB)
```

빌드 환경의 GLIBC 버전이 실행 환경과 같거나 낮아야 합니다.

### Static 빌드 (이식성 최대)

GLIBC 버전에 무관하게 어떤 Linux x86_64에서도 동작하는 독립 실행 바이너리를 생성합니다.

| 타겟 | 결과물 | 크기 | 설명 |
|------|--------|------|------|
| `make static` | `multi-fec-static` | 1.5 MB | 정적 빌드 (디버그 심볼 포함) |
| `make static-strip` | `multi-fec-dist` | 1.3 MB | 배포용 (디버그 심볼 제거) |

**배포용 빌드 및 복사:**
```bash
make static-strip
# 결과물: ./multi-fec-dist (1.3 MB)

scp multi-fec-dist user@서버:/usr/local/bin/multi-fec
```

### GLIBC 버전 불일치 오류 시

```
./multi-fec: /lib/x86_64-linux-gnu/libc.so.6: version `GLIBC_2.38' not found
```

빌드 환경(예: Ubuntu 24.04)이 실행 환경(예: Ubuntu 22.04)보다 GLIBC가 높을 때 발생합니다.

**해결 방법 1: Static 빌드 사용 (권장)**
```bash
make static-strip
scp multi-fec-dist user@서버:/usr/local/bin/multi-fec
```

**해결 방법 2: Docker로 실행 환경과 동일한 OS에서 빌드**
```bash
docker run --rm \
  -v $(pwd):/src \
  ubuntu:22.04 \
  bash -c "apt-get update -q && apt-get install -y -q g++ make && cd /src && make clean && make -j$(nproc)"
```

**해결 방법 3: 실행 서버에서 직접 빌드**
```bash
scp -r /path/to/multi_fec user@서버:~/
ssh user@서버 "cd ~/multi_fec && apt install -y g++ make && make -j\$(nproc)"
```

| 방법 | 바이너리 크기 | 이식성 | 비고 |
|------|-------------|--------|------|
| `make static-strip` | 1.3 MB | 모든 Linux x86_64 | 권장 |
| Docker 빌드 | 279 KB | 빌드 OS 이상 | Docker 필요 |
| 서버 직접 빌드 | 279 KB | 해당 서버 | SSH 접근 필요 |

---

## 동작 모드

| 모드 | 옵션 | 역할 |
|------|------|------|
| 클라이언트 | `-c` | WireGuard 트래픽 수신 → FEC 인코드 → 서버로 송신 |
| 서버 | `-s` | 클라이언트 수신 → FEC 디코드 → WireGuard 포워드 |
| 릴레이(POP) | `-r` | 투명 UDP 포워더. FEC/obfs 미처리 |

---

## 기본 구성 (2-노드: 클라이언트 ↔ 서버)

```
[WireGuard 클라이언트 :51820]
        ↕ UDP
[multi-fec 클라이언트 :51820] ── UDP/443 ──▶ [multi-fec 서버 :443]
                                                      ↕ UDP
                                             [WireGuard 서버 :51820]
```

**서버** (IP: 1.2.3.4)
```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k mysecret \
  --obfs-mode tls \
  -f 10:3
```

**클라이언트**
```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:1.2.3.4:443 \
  -k mysecret \
  --obfs-mode tls \
  -f 10:3
```

WireGuard 클라이언트의 Endpoint를 `127.0.0.1:51820`으로 설정합니다.

---

## 다중 경로 구성

### failover 모드 (장애 시 자동 전환)

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 192.168.1.10:1.2.3.4:443 \   # eth0 (1순위)
  --path 10.0.0.2:1.2.3.4:443 \       # wlan0 (2순위)
  -k mysecret \
  --multipath-mode failover
```

`--path` 나열 순서가 우선순위입니다. 1순위 경로 장애 시 자동으로 다음 경로로 전환됩니다.

### duplicate 모드 (모든 경로 동시 전송)

```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 192.168.1.10:1.2.3.4:443 \
  --path 10.0.0.2:1.2.3.4:443 \
  -k mysecret \
  --multipath-mode duplicate
```

모든 경로에 동일 패킷을 동시 전송하고 서버에서 중복을 제거합니다.
대역폭 소비가 경로 수 배가 되지만 지연과 손실에 가장 강합니다.

---

## POP 릴레이 경유 구성

지리적으로 유리한 중간 서버(POP)를 경유해 지연을 줄이거나 경로를 다양화합니다.

```
클라이언트 ──path1 (직접)───────────────────▶ 서버
           ──path2 (일본 POP 경유)──▶ [POP] ──▶ 서버
           ──path3 (싱가포르 POP 경유)──▶ [POP] ──▶ 서버
```

**서버** (1.2.3.4)
```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k mysecret \
  --obfs-mode tls \
  -f 10:3
```

**일본 POP** (5.6.7.8) — 키 불필요
```bash
# 투명 릴레이 (HMAC 검증 없음)
multi-fec -r \
  -l 0.0.0.0:443 \
  --upstream 1.2.3.4:443

# HMAC 검증 활성화 (권장 — 불법 트래픽 차단)
multi-fec -r \
  -l 0.0.0.0:443 \
  --upstream 1.2.3.4:443 \
  -k mysecret \
  --obfs-mode tls
```

**싱가포르 POP** (9.10.11.12)
```bash
multi-fec -r \
  -l 0.0.0.0:443 \
  --upstream 1.2.3.4:443 \
  -k mysecret \
  --obfs-mode tls
```

**클라이언트**
```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:1.2.3.4:443 \        # 직접
  --path 0.0.0.0:5.6.7.8:443 \        # 일본 POP 경유
  --path 0.0.0.0:9.10.11.12:443 \     # 싱가포르 POP 경유
  -k mysecret \
  --obfs-mode tls \
  --multipath-mode duplicate \
  -f 10:3
```

---

## GFW 우회 설정

### 포트 및 obfs 모드 선택

| 상황 | 설정 |
|------|------|
| UDP/443, QUIC 위장 | `--obfs-mode quic` (기본값) |
| UDP/443, TLS 위장 | `--obfs-mode tls` |
| GFW 없는 내부망 | `--disable-obfs` |

UDP/443 + `--obfs-mode tls` 조합이 GFW 회피에 가장 효과적입니다.
TCP/443은 nginx/caddy가 독립적으로 처리하며 multi-fec와 충돌 없이 공존합니다.

### TCP/443 공존 확인

```bash
ss -ulnp | grep :443   # UDP/443 사용 중인 프로세스 (multi-fec)
ss -tlnp | grep :443   # TCP/443 사용 중인 프로세스 (nginx/caddy)
```

### GFW 액티브 프로빙 대응

HMAC 검증 실패 패킷(GFW 스캐너)에 TLS `close_notify` alert (7 bytes)를 자동 응답합니다.
프로버 입장에서 정상 TLS 서버처럼 보여 차단을 피합니다.

---

## 포트 선택 가이드

| 포트 | obfs 모드 | 적합한 환경 |
|------|-----------|------------|
| UDP/443 | `tls` / `quic` | GFW 우회 최우선 |
| UDP/8443 | `tls` | 443이 이미 사용 중일 때 |
| UDP/4096 | 없음 | GFW 없는 내부망 |

---

## FEC 설정

### 비율 (`-f x:y`)

데이터 x 패킷당 패리티 y 패킷 생성. y/x 비율이 복구 가능한 최대 손실률입니다.

```bash
-f 10:2    # 20% 손실까지 복구, 오버헤드 20%
-f 10:4    # 40% 손실까지 복구, 오버헤드 40%
-f 10:6    # 60% 손실까지 복구, 오버헤드 60%
```

### 모드 (`--mode`)

```bash
--mode 0   # 대역폭 절약 (기본). 그룹 완성 후 패리티 일괄 전송
--mode 1   # 저지연. 데이터 패킷마다 즉시 패리티 전송
```

### timeout (`--fec-timeout`)

FEC 그룹이 채워지지 않을 때 강제 전송 대기 시간 (ms).

```bash
--fec-timeout 2    # 저지연 (2ms 대기)
--fec-timeout 8    # 기본값
--fec-timeout 20   # 저대역폭 링크 (그룹 채울 시간 확보)
```

### 상황별 권장 설정

| 용도 | 설정 |
|------|------|
| 게임 / 화상통화 (저지연) | `-f 10:3 --mode 1 --fec-timeout 2` |
| 파일 전송 (고복구율) | `-f 10:6 --mode 0 --fec-timeout 8` |
| duplicate 3경로 | `-f 10:2 --mode 1` (duplicate 자체가 복구 역할) |
| FEC 불필요 | `--disable-fec` |

---

## RTT 오버헤드

| 설정 | 추가 RTT |
|------|---------|
| `--disable-fec` | < 0.1 ms |
| `-f 10:3 --mode 1 --fec-timeout 2` | < 1 ms |
| `-f 20:10 --mode 0 --fec-timeout 8` | 2 – 8 ms |
| obfs encode/decode | < 1 µs (무시 가능) |

---

## 런타임 실시간 설정 변경

`--fifo PATH` 옵션으로 FIFO 파일을 만들고, 실행 중에 명령을 주입합니다.

```bash
# 실행 시 FIFO 지정
multi-fec -c -l 127.0.0.1:51820 --path 0.0.0.0:1.2.3.4:443 -k mysecret \
  --fifo /tmp/mf-client.fifo

# 실행 중 명령 전송
echo "fec 10:2"    > /tmp/mf-client.fifo   # FEC 비율 변경
echo "timeout 2"   > /tmp/mf-client.fifo   # FEC timeout 변경
echo "mode 1"      > /tmp/mf-client.fifo   # 저지연 모드 전환
echo "mtu 1100"    > /tmp/mf-client.fifo   # MTU 조정
echo "queue-len 100" > /tmp/mf-client.fifo # 큐 길이 조정

# 여러 명령 동시 적용
printf "fec 10:2\ntimeout 2\nmode 1\n" > /tmp/mf-client.fifo
```

재시작이 필요한 항목: `-k` 키, `--path` 경로 추가/삭제, `-l` 주소, `--obfs-mode`, `--multipath-mode`

---

## 통계 모니터링 (`--report`)

```bash
multi-fec -s -l 0.0.0.0:443 --wg 127.0.0.1:51820 -k mysecret --report 5
# 5초마다 경로별 RTT/손실률/처리량 출력
```

---

## 옵션 요약표

| 옵션 | 모드 | 기본값 | 설명 |
|------|------|--------|------|
| `-c` | — | — | 클라이언트 모드 |
| `-s` | — | — | 서버 모드 |
| `-r` | — | — | 릴레이(POP) 모드 |
| `-l ip:port` | 전체 | — | 로컬 리슨 주소 |
| `--path local:remote:port` | 클라이언트 | — | 경로 추가 (반복 가능) |
| `--multipath-mode M` | 클라이언트 | `failover` | `failover` / `duplicate` |
| `--wg ip:port` | 서버 | — | WireGuard 업스트림 주소 |
| `--upstream ip:port` | 릴레이 | — | 서버 주소 |
| `-k keystring` | 클라이언트/서버 | `default-key` | 사전 공유 키 |
| `-f x:y` | 클라이언트/서버 | `20:10` | FEC 비율 |
| `--fec-timeout N` | 클라이언트/서버 | `8` ms | FEC 그룹 flush 대기 |
| `--mode 0\|1` | 클라이언트/서버 | `0` | FEC 모드 |
| `--mtu N` | 클라이언트/서버 | `1250` | FEC 패킷 MTU |
| `--decode-buf N` | 클라이언트/서버 | `2000` | FEC 디코더 링버퍼 |
| `--disable-fec` | 클라이언트/서버 | off | FEC 비활성화 |
| `--obfs-mode M` | 클라이언트/서버 | `quic` | `quic` / `tls` |
| `--disable-obfs` | 클라이언트/서버 | off | 난독화 비활성화 |
| `--sock-buf N` | 전체 | OS | UDP 소켓 버퍼 (kB) |
| `--fifo PATH` | 전체 | — | 런타임 커맨드 FIFO |
| `--report N` | 전체 | `0` | 통계 출력 주기 (초) |
| `--log-level N` | 전체 | `4` | 로그 레벨 0–6 |
| `-j N` | 전체 | `0` | 인공 지터 (ms, 테스트용) |
| `--random-drop N` | 전체 | `0` | 인공 패킷 손실 N/10000 |
| `-h` | — | — | 도움말 출력 |

---

## systemd 서비스

### 파일 구조

```
/usr/local/bin/multi-fec                        ← 바이너리
/etc/multi-fec/server.conf                      ← 서버 환경변수
/etc/multi-fec/client.conf                      ← 클라이언트 환경변수
/etc/multi-fec/relay.conf                       ← 릴레이 환경변수
/etc/systemd/system/multi-fec-server.service
/etc/systemd/system/multi-fec-client.service
/etc/systemd/system/multi-fec-relay.service
/run/multi-fec/                                 ← FIFO (런타임)
```

### 바이너리 설치

```bash
make static-strip
cp multi-fec-dist /usr/local/bin/multi-fec
chmod 755 /usr/local/bin/multi-fec
mkdir -p /etc/multi-fec
```

---

### 서버

**/etc/multi-fec/server.conf**
```bash
LISTEN=0.0.0.0:443
WG=127.0.0.1:51820
KEY=mysecret
OBFS_MODE=tls
FEC=10:3
FEC_MODE=1
FEC_TIMEOUT=4
LOG_LEVEL=4
REPORT=60
```

**/etc/systemd/system/multi-fec-server.service**
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
    -l ${LISTEN} \
    --wg ${WG} \
    -k ${KEY} \
    --obfs-mode ${OBFS_MODE} \
    -f ${FEC} \
    --mode ${FEC_MODE} \
    --fec-timeout ${FEC_TIMEOUT} \
    --report ${REPORT} \
    --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/server.fifo
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

### 클라이언트

**/etc/multi-fec/client.conf**
```bash
LISTEN=127.0.0.1:51820
KEY=mysecret
OBFS_MODE=tls
MULTIPATH_MODE=duplicate
FEC=10:3
FEC_MODE=1
FEC_TIMEOUT=4
LOG_LEVEL=4
REPORT=60
```

**/etc/systemd/system/multi-fec-client.service**
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
    --path 0.0.0.0:1.2.3.4:443 \
    --path 0.0.0.0:5.6.7.8:443 \
    -k ${KEY} \
    --obfs-mode ${OBFS_MODE} \
    --multipath-mode ${MULTIPATH_MODE} \
    -f ${FEC} \
    --mode ${FEC_MODE} \
    --fec-timeout ${FEC_TIMEOUT} \
    --report ${REPORT} \
    --log-level ${LOG_LEVEL} \
    --fifo /run/multi-fec/client.fifo
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

> `--path`는 반복 옵션이므로 환경변수로 분리하지 않고 `ExecStart`에 직접 나열합니다.

---

### 릴레이(POP)

**/etc/multi-fec/relay.conf**
```bash
LISTEN=0.0.0.0:443
UPSTREAM=1.2.3.4:443
KEY=mysecret
OBFS_MODE=tls
LOG_LEVEL=4
```

**/etc/systemd/system/multi-fec-relay.service**
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
    -l ${LISTEN} \
    --upstream ${UPSTREAM} \
    -k ${KEY} \
    --obfs-mode ${OBFS_MODE} \
    --log-level ${LOG_LEVEL}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
```

---

### 활성화 및 관리

```bash
systemctl daemon-reload

# 서버
systemctl enable --now multi-fec-server
systemctl status       multi-fec-server

# 클라이언트
systemctl enable --now multi-fec-client

# 릴레이
systemctl enable --now multi-fec-relay

# 로그 확인
journalctl -u multi-fec-server -f
journalctl -u multi-fec-server --since "10 min ago"

# 재시작
systemctl restart multi-fec-server
```

### 런타임 FEC 변경 (FIFO)

```bash
# 서버
echo "fec 10:2"   > /run/multi-fec/server.fifo
echo "timeout 2"  > /run/multi-fec/server.fifo
echo "mode 1"     > /run/multi-fec/server.fifo

# 클라이언트
echo "fec 10:5"   > /run/multi-fec/client.fifo
echo "timeout 8"  > /run/multi-fec/client.fifo
```

### keepalived 연동

VIP 환경에서 keepalived와 연동할 경우 `After`/`BindsTo`를 추가합니다:

```ini
[Unit]
After=network-online.target keepalived.service
Wants=network-online.target
BindsTo=keepalived.service
```

---

## 방화벽 설정

**서버 / POP (iptables)**
```bash
# UDP 포트 개방
iptables -A INPUT -p udp --dport 443 -j ACCEPT

# 추가 보안: hashlimit으로 소스 IP당 속도 제한
iptables -A INPUT -p udp --dport 443 \
  -m hashlimit \
  --hashlimit-name mf_udp443 \
  --hashlimit-above 2000/sec \
  --hashlimit-burst 4000 \
  --hashlimit-mode srcip \
  -j DROP
```

**클라이언트 IP가 고정인 경우 (POP)**
```bash
iptables -A INPUT -p udp --dport 443 -s <CLIENT_IP> -j ACCEPT
iptables -A INPUT -p udp --dport 443 -j DROP
```
