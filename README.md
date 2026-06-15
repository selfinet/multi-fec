# multi-fec

**UDPspeeder V2 FEC + glorytun mud_lite 멀티패스 + GFW 난독화**를 결합한 UDP 프록시.

WireGuard와 네트워크 사이에서 동작하며 **FEC 손실 복구**, **다중 경로 대역폭 집계**, **심층 패킷 검사(DPI) 우회**를 동시에 제공합니다. 고RTT·고손실 국제 회선에서 WireGuard 처리량과 안정성을 끌어올리기 위해 설계되었습니다.

```
[WireGuard 클라이언트]
        │ UDP
[multi-fec 클라이언트] ──path1(직접)──────────────▶ [multi-fec 서버]
                       ──path2(POP 경유)──▶ [릴레이] ──▶      │ UDP
                                                        [WireGuard 서버]
```

---

## 주요 기능

| 기능 | 설명 |
|------|------|
| **FEC 손실 복구** | Reed-Solomon 기반 전방 오류 정정. `x:y` 비율로 데이터 x개당 복구 y개 전송 → 재전송 없이 패킷 손실 복구 |
| **멀티패스** | 단일 UDP 소켓 + `IP_PKTINFO`로 여러 경로 동시 사용. failover / duplicate / aggregate / aggregate-duplicate 4개 모드 |
| **대역폭 집계** | `aggregate` 모드로 복수 ISP 회선·해저케이블 대역폭을 실제로 합산 (tx.rate 비례 가중 분배) |
| **GFW 난독화** | QUIC/TLS 위장 + SipHash HMAC 인증. RFC 9000 준수 QUIC Initial 핸드쉐이크 시뮬레이션 |
| **액티브 프로빙 대응** | HMAC 실패 시 내장 QUIC Server Initial 응답(nginx 불필요) 또는 `--decoy`로 실제 QUIC 서버 중계 |
| **세션 집계** | 8바이트 session_id로 POP 경유 여부와 무관하게 동일 클라이언트를 단일 FEC 세션으로 처리 |
| **포트 호핑** | TOTP 기반 포트 호핑(`--port-hop-interval`)으로 고정 포트 탐지 회피 |
| **런타임 제어** | FIFO를 통한 FEC 비율/MTU/모드 무중단 변경 |

---

## 동작 모드

| 모드 | 플래그 | 역할 |
|------|--------|------|
| **클라이언트** | `-c` | WireGuard 로컬 포트 수신 → FEC 인코드 → obfs → mud_lite 송신 |
| **서버** | `-s` | mud_lite 수신 → obfs 디코드 → FEC 디코드 → WireGuard 포워드 |
| **릴레이(POP)** | `-r` | 투명 UDP 포워더. FEC/obfs 미처리, raw bytes 중계 (키별 라우팅 지원) |

---

## 빌드

의존성: gcc/g++ (C11/C++11), libev (`libev/`에 동봉), librt, libpthread

```bash
make -j$(nproc)        # 동적 링크 빌드 → ./multi-fec        (~279 KB)
make static            # 정적 링크 빌드 → ./multi-fec-static  (~1.5 MB)
make static-strip      # 배포용 정적 빌드 → ./multi-fec-dist  (~1.3 MB, 심볼 제거)
make clean             # 클린
```

> **GLIBC 버전 불일치**(예: 빌드 환경 Ubuntu 24.04 → 실행 환경 22.04) 발생 시 `make static-strip`으로 정적 빌드 후 배포하세요.

---

## 빠른 시작

### 기본 구성 (클라이언트 ↔ 서버 직접 연결)

**서버:**
```bash
multi-fec -s \
  -l 0.0.0.0:443 \
  --wg 127.0.0.1:51820 \
  -k STRONGKEY \
  --obfs-mode quic \
  -f 20:4
```

**클라이언트:**
```bash
multi-fec -c \
  -l 127.0.0.1:51820 \
  --path 0.0.0.0:서버IP:443 \
  -k STRONGKEY \
  --obfs-mode quic \
  -f 20:4
```

WireGuard는 `Endpoint = 127.0.0.1:51820`(클라이언트), 리슨 `51820`(서버)로 설정합니다.

> **WireGuard MTU는 1300 권장.** 기본값(1420)은 multi-fec 오버헤드 추가 후 경로 MTU를 초과해 IP 단편화를 유발합니다. 단편화 제거 시 실측 처리량 약 37% 향상.

### 멀티패스 대역폭 집계 (두 ISP 회선)

```bash
multi-fec -c -l 127.0.0.1:51820 \
    --path 192.168.1.x:서버IP:443 \
    --path 10.0.0.x:서버IP:443 \
    --multipath-mode aggregate -f 20:1
```

> 서로 다른 서브넷의 인터페이스를 쓸 때는 **policy routing 설정이 필수**입니다 (각 소스 IP가 올바른 인터페이스로 나가도록).

### 릴레이(POP) 경유 — 키별 라우팅

```bash
multi-fec -r -l 0.0.0.0:443 \
    --route "keyA 1.2.3.4:443" \
    --route "keyB 5.6.7.8:443" \
    --decoy 127.0.0.1:8443
```

---

## 멀티패스 모드

| 모드 | 동작 | 처리량 | 가용성 |
|------|------|--------|--------|
| `failover` | 최우선 경로만 사용, 장애 시 다음 경로 | 단일 경로 | Active-Standby |
| `duplicate` | 모든 경로에 동일 패킷 동시 전송 | 단일 경로(중복) | 최고 |
| `aggregate` | 경로별 다른 패킷 분배 (가중 라운드로빈) | **경로 합산** | 단일 경로 수준 |
| `aggregate-duplicate` | 패킷당 `--dup-factor`개 경로에 전송 | 집계 효과 | 집계+이중화 혼합 |

---

## 주요 CLI 옵션

### 공통
| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `-l ip:port` | 필수 | 로컬 리슨 주소 |
| `-k keystring` | `default-key` | PSK (릴레이는 선택) |
| `--obfs-mode quic\|tls` | `quic` | 패킷 위장 모드 |
| `--auth-interval N` | `30` | HMAC 토큰 슬롯 길이(초). 양쪽 동일 설정 필수. 권장 `60` |
| `--report N` | `0` | 통계 리포트 주기(초) |
| `--log-level 0–6` | `4` | 로그 레벨 |

### 클라이언트
| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `--path L:R:P` | 필수 | 멀티패스 경로(반복 가능). L=소스IP, R=서버IP, P=포트 |
| `--multipath-mode M` | `failover` | failover/duplicate/aggregate/aggregate-duplicate |
| `--dup-factor N` | `2` | aggregate-duplicate에서 패킷당 경로 수 (1–8) |
| `--port-hop-interval N` | `0` | TOTP 포트 호핑 슬롯(초). 0=비활성 |

### 서버
| 옵션 | 설명 |
|------|------|
| `--wg ip:port` | WireGuard upstream 주소 (필수) |
| `--decoy ip:port` | GFW 액티브 프로빙 대응. 미지정 시 내장 QUIC Server Initial로 자동 응답 |

### 릴레이
| 옵션 | 설명 |
|------|------|
| `--upstream ip:port` | 단일 upstream 서버 주소 |
| `--route "key ip:port"` | 키별 upstream 라우팅(반복 가능). `--upstream`과 혼용 불가 |
| `--decoy ip:port` | 서버와 동일한 프로빙 대응 |

### FEC
| 옵션 | 기본값 | 설명 |
|------|--------|------|
| `-f x:y` | `20:10` | FEC 비율. x=데이터, y=복구 패킷 수 |
| `--fec-timeout N` | `8` | FEC 그룹 flush 대기(ms) |
| `--mode 0\|1` | `0` | 0=대역폭 절약(큐 기반), 1=저지연 |
| `--mtu N` | `1250` | FEC 패킷 MTU (WG MTU 1300 기준 1250 권장) |
| `--decode-buf N` | `2000` | FEC 디코더 링버퍼 크기 |

> 전체 옵션은 `multi-fec -h` 또는 [`OPTIONS.md`](OPTIONS.md) 참고.

---

## 손실률별 FEC 권장 설정

| 링크 상태 | FEC 설정 | 오버헤드 | 커버 손실률 |
|-----------|---------|---------|-----------|
| 안정적 (손실 1~3%) | `-f 20:2` | 10% | 최대 9% |
| 일반 (손실 3~8%) | `-f 20:4` | 20% | 최대 16% |
| 불안정 (손실 8~15%) | `-f 20:7` | 35% | 최대 25% |

손실률을 모를 때는 `-f 20:4`로 시작해 `--report 30`으로 모니터링하며 조정하세요.

### 인터랙티브 트래픽(게임·화상통화)

낮은 지연이 목표일 때:
```bash
--mode 1 --fec-timeout 5 -f 10:3 --queue-len 100
```

---

## FIFO 런타임 커맨드

`--fifo PATH` 지정 시 무중단으로 변경 가능:

```bash
echo "fec 10:3"   > /run/multi-fec/server.fifo   # FEC 비율 변경
echo "mtu 1200"   > /run/multi-fec/server.fifo    # MTU 변경
echo "mode 1"     > /run/multi-fec/server.fifo    # FEC 모드 전환
```

지원: `fec x:y`, `mtu N`, `mode 0|1`, `timeout N`, `queue-len N`
(`--multipath-mode` 변경은 FIFO 미지원 — 재시작 필요)

---

## 문서

| 파일 | 내용 |
|------|------|
| [`CLAUDE.md`](CLAUDE.md) | 개발자 레퍼런스 (소스 구조, 핵심 설계, 내부 수치, 버그 수정 이력) |
| [`OPTIONS.md`](OPTIONS.md) | 전체 CLI 옵션 상세 |
| [`DEPLOY_EXAMPLES.md`](DEPLOY_EXAMPLES.md) | 10가지 배포 시나리오별 전체 설정 예제 |

---

## systemd 서비스

환경변수 파일(`/etc/multi-fec/*.conf`)과 서비스 파일을 분리해 관리합니다.
서버/클라이언트/릴레이 서비스 유닛 예시는 [`CLAUDE.md`](CLAUDE.md)의 **systemd 서비스** 섹션을 참고하세요.

```bash
systemctl daemon-reload
systemctl enable --now multi-fec-server   # 또는 client / relay
journalctl -u multi-fec-server -f
```

---

## 테스트

```bash
python3 test_relay_routing.py    # 릴레이 키별 라우팅 (7 케이스)
python3 test_all_options.py      # 전체 CLI 옵션 (90 케이스)
python3 test_perf_stability.py   # 성능·안정성 (26 케이스)
```

---

## 알려진 제약

- `--path`, `-k`, `--obfs-mode`, `--multipath-mode`, `--dup-factor` 변경은 **재시작 필요** (FIFO 미지원)
- mud_lite는 단일 UDP 소켓 기반으로 커널 멀티큐 미지원
- 릴레이 키별 라우팅: 동일 (src_ip, src_port) 세션은 최초 키로 고정, 재협상 없음
- WireGuard MTU를 1420으로 두면 IP 단편화 발생 → **MTU 1300 권장**
