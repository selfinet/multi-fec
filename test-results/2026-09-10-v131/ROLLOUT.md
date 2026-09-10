# v1.3.1 적용 런북 — 호스트별 실행 명령

- **대상 바이너리**: sv1 `/home/stevekim/multi-fec/multi-fec-dist`
  · `multi-fec 1.3.1` · md5 **`ccdeef600f4aca1d7c8a20423e48af5c`**
- **이 md5 가 검증에 쓴 바로 그 산출물이다.** 재빌드하면 바이트가 달라진다(빌드 시각이
  버전 문자열에 들어간다) — 그러면 "시험한 것과 같은 바이너리" 라고 말할 수 없다.
- **와이어 무변경 · 클라이언트 단독 수정** → 순서 자유, 부분 교체·혼용·롤백 가능.
- 서비스망 구성: `c ─┬─► r1a ─► r2a ─┬─► s` / `└─► r1b ─► r2b ─┘` (릴레이 4, 2단 2경로)

---

## 0. sv1 에서 — 전달 (교체 아님)

```bash
cd /home/stevekim/multi-fec
md5sum multi-fec-dist          # ccdeef600f4aca1d7c8a20423e48af5c 확인

# 각 호스트로 옮긴다 (호스트명·경로는 환경에 맞게)
for H in c r1a r1b r2a r2b s; do
  scp multi-fec-dist "$H":/tmp/mfd131
done
```

sv1 자신의 `/usr/sbin/multi-fec-dist` 는 **건드리지 않는다**(운영 서비스가 돈다).

---

## 1. 모든 호스트 공통 — 백업 → 설치 → 재시작

각 호스트에서 **root** 로 실행. `<UNIT>` 은 §2 의 역할별 유닛 이름.

```bash
# (1) 현재 버전 기록 + 백업  ← 롤백의 전제. 건너뛰지 말 것
V=$(/usr/sbin/multi-fec-dist --version 2>&1 | head -1 | awk '{print $2}')
cp -a /usr/sbin/multi-fec-dist "/usr/sbin/multi-fec-dist.bak-$V"
md5sum /usr/sbin/multi-fec-dist "/usr/sbin/multi-fec-dist.bak-$V"

# (2) 유닛 이름 확인 (환경마다 다르다)
systemctl list-units --all 'multi-fec*' --no-pager

# (3) 설치 — 실행 중 프로세스는 기존 inode 를 계속 쓰므로 이 시점엔 무영향
install -m755 /tmp/mfd131 /usr/sbin/multi-fec-dist && rm -f /tmp/mfd131
md5sum /usr/sbin/multi-fec-dist            # ccdeef60... 확인
/usr/sbin/multi-fec-dist --version | head -1   # multi-fec 1.3.1

# (4) 재시작 — 여기서 순단이 발생한다
systemctl restart <UNIT>
sleep 3; systemctl is-active <UNIT>
```

---

## 2. 역할별 — 유닛과 확인 명령

### 2-가. `s` (서버) — 먼저 올린다

```bash
# 유닛: multi-fec-server
systemctl restart multi-fec-server
journalctl -u multi-fec-server -n 30 --no-pager -o cat | grep -E 'listening|new session|new client|report'
```

확인할 것: `listening at`, 각 지사의 `new session`, `--report` 카운터가 **증가**하는지.
경고가 보이면 안 되는 것: `mud 경로 테이블 소진` (동시 피어 32 상한 — §28).

### 2-나. `r2a` · `r2b` (서버쪽 2단) → `r1a` · `r1b` (클라이언트쪽 1단)

```bash
# 유닛: 인스턴스가 2개면 multi-fec-relay, multi-fec-relay@b 형태
systemctl restart multi-fec-relay          # 인스턴스별로 각각
journalctl -u multi-fec-relay -n 30 --no-pager -o cat | grep -E 'relay|route|new session'

# 세션·FD 회수 확인 (릴레이는 세션 1개 = upstream 소켓 1개)
P=$(systemctl show -p MainPID --value multi-fec-relay); ls /proc/$P/fd | wc -l
ss -unp | grep -c "pid=$P"
```

확인할 것: 기동 로그의 `route[i] key=kf:...`(지문) 과 upstream 주소, 클라이언트 패킷 도착 시
`new session`. **`--auth-interval` 이 4개 홉과 c·s 에서 전부 같아야 한다** — 하나만 어긋나면
그 경로가 조용히 폐기된다(증상: 경로 DEGRADED, `new session` 로그 없음).

### 2-다. `c` (클라이언트) — 마지막에 올린다

```bash
# 유닛: multi-fec-client
systemctl restart multi-fec-client
sleep 5
journalctl -u multi-fec-client -n 40 --no-pager -o cat | grep -E 'listening|static path|RUNNING|DEGRADED|LOSSY|stale|flushed'
```

확인할 것:
- `path[0] RUNNING` · `path[1] RUNNING` **둘 다** (LOSSY/DEGRADED 가 남으면 그 경로 점검)
- 터널 왕복: `ping -c 20 -i 0.2 -I <터널 로컬IP> <터널 상대IP>` → 손실 0%, RTT 가 평소값
- v1.3.1 신규 로그(단절이 있었을 때만): `dropped N stale pending packet(s) (>1000 ms)`

---

## 3. 적용 후 30분 관찰

```bash
# 각 호스트: 프로세스 RSS·FD 가 계단 후 평탄해지는지 (누수 판정은 계단·평탄 구간으로)
P=$(systemctl show -p MainPID --value <UNIT>)
while :; do
  printf '%s rss=%s kB fd=%s\n' "$(date +%T)" \
    "$(awk '/VmRSS/{print $2}' /proc/$P/status)" "$(ls /proc/$P/fd | wc -l)"
  sleep 60
done
```

기대: RSS 는 연결당 FEC 링버퍼가 채워지는 램프(수십 분) 후 고정, **FD 는 처음부터 고정**.

---

## 4. 롤백 (1줄 + 재시작)

```bash
install -m755 /usr/sbin/multi-fec-dist.bak-<이전버전> /usr/sbin/multi-fec-dist
systemctl restart <UNIT>
/usr/sbin/multi-fec-dist --version | head -1
```

와이어 무변경이라 **일부 호스트만 롤백해도 통신이 유지된다.**

---

## 5. 주의

1. **`ps` 와 systemd unit 에는 PSK 가 평문으로 보인다** — 로그 마스킹(v1.0.6) 범위 밖이다.
   런북 출력이나 티켓에 `ps` 결과를 붙일 때 키가 새지 않게 할 것.
2. **재시작은 순단이다** — 세션 인계가 없다(SIGTERM 즉시 종료). 릴레이는 인스턴스가 2개
   이상이므로 **한 번에 하나씩** 재시작하면 duplicate 가 커버한다(1경로 장애 공백 0 실측).
   단 2단 구성에서는 **서로 다른 체인의 인스턴스를 동시에 재시작하면 전면 단절**이다.
3. `s` 의 동시 피어 상한은 **32**(경로 수 기준). 2경로면 지사 1곳이 2슬롯 → 서버 프로세스당
   지사 16곳, 안전선 12. 마지막 단 릴레이를 재시작하면 옛 슬롯이 최대 5분 남는다.
4. 버전 문자열을 `v1.3.1` 로 깔끔하게 내려면 태그 후 재빌드가 필요한데, 그러면 **위 md5 와
   달라진다**. 검증 산출물과의 동일성을 우선하려면 이 바이너리를 그대로 쓸 것.

---

## 6. 단계 전환 — 릴레이·서버부터, 클라이언트는 나중에 (2026-09-11 결정)

구버전(6/19 `local-build`)이 남은 상태로 **s → r 먼저** 올린다. 근거: 가장 시급한 세 결함이
전부 그쪽에 있다 — §23 PSK 로그 노출(릴레이 `--route`), §24 손실률 래치로 이중화 무력화,
§22-가 FEC 디코더 abort. **구 클라이언트는 그대로 붙는다**(와이어 무변경, v1.0.1 때 교차
16종 실측).

### 6-가. 순서와 각 단계의 순단

| 단계 | 대상 | 순단 | 비고 |
|---|---|---|---|
| 1 | `s` 서버 프로세스 — **지사 하나씩** | 약 2~3초 | 재기동 후 WG 재핸드셰이크. 실측: 복구 +2.0초에 통신 재개 |
| 2 | `r2a` → (확인) → `r2b` | **0** | duplicate 가 남은 경로로 전량 나른다(실측 공백 0) |
| 3 | `r1a` → (확인) → `r1b` | **0** | 같은 이유 |
| 4 | `c` (나중에, 지사별로) | 약 2~3초 | §29(묵은 패킷) 효과는 이때 생긴다 |

⚠️ **같은 체인의 1단·2단을 동시에 재시작하지 말 것**(`r1a`+`r2a` 동시 = 그 경로 소멸).
⚠️ **서로 다른 체인을 동시에 재시작하지 말 것**(`r1a`+`r1b` 동시 = 전면 단절).
한 인스턴스를 올린 뒤 경로가 RUNNING 으로 돌아온 것을 확인하고 다음으로 넘어간다.

### 6-나. 구 클라이언트를 유지하는 동안 맞춰야 하는 값

새 서버·릴레이 설정에서 **바꾸면 안 되는 것** (구 클라가 못 따라온다):

| 항목 | 반드시 유지 |
|---|---|
| `-k` PSK | 지사별 기존 값 |
| `--auth-interval` | **기존 값과 동일**(현 운영 60). 어긋나면 그 경로가 조용히 폐기된다 |
| `--mode` | 기존 값과 동일(현 운영 `--mode 1`) |
| `--mtu` / WG MTU | 기존 조합 유지(1350 / 1300) |

**바꿔도 되는 것** (송신측 각자 값이라 상대가 헤더로 읽는다):

| 항목 | 권장 |
|---|---|
| `-f` | `20:5` → **`5:1,20:4`** — 저레이트 오버헤드가 크게 줄고 구 클라도 그대로 디코드한다 |
| `--decode-buf` | `8000` → **`2000`** — 연결당 31.7 MB → 9.4 MB |

### 6-다. 단계별 확인

```bash
# s: 해당 지사 프로세스만 재기동한 뒤
journalctl -u <해당 유닛> -n 20 --no-pager -o cat | grep -E 'listening|new session|report'
#   → report 카운터가 증가하면 구 클라가 붙은 것이다

# r: 인스턴스 하나 올린 뒤 (다음 인스턴스로 넘어가기 전에)
journalctl -u <해당 유닛> -n 20 --no-pager -o cat | grep -E 'route\[|new session'
#   → key 가 평문이 아니라 kf:xxxxxxxx 지문으로 찍히면 §23 이 해소된 것이다

# c 쪽에서 (구 클라이언트에서도 확인 가능)
journalctl -u multi-fec-client -n 30 --no-pager -o cat | grep -E 'RUNNING|LOSSY|DEGRADED'
#   → path[0]·path[1] 둘 다 RUNNING. LOSSY 가 사라지지 않으면 §24 래치가 남은 구 클라 쪽이다
ping -c 20 -i 0.2 -I <터널 로컬IP> <터널 상대IP>     # 손실 0%
```

### 6-라. 남는 것 (클라이언트를 올릴 때까지)

- **§24 래치는 클라이언트 쪽에도 있다** — 서버를 올려도 구 클라의 `tx.loss` 계산은 그대로다.
  이중화가 완전히 회복되는 것은 c 를 올린 뒤다.
- **§29 묵은 패킷**(복구 시 최대 27초)도 클라이언트 수정이라 c 를 올려야 사라진다.
- 이미 기록된 로그의 평문 PSK 는 바이너리 교체로 사라지지 않는다 → 필요하면 **키 교체
  (양쪽 동시)** 나 journal 정리를 별도로.
