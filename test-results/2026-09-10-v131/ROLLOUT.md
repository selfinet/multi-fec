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

---

## 7. 실서비스망 적용 실기록 (2026-09-11 완료)

§6 의 롤링이 아니라 **전면 정지 후 일괄 교체**로 진행했다. 서비스망은 §0 의 4릴레이 구성이
아니라 **지사별로 1단 직결 + 2단 캐스케이드를 병행**하는 형태였다(역할명만 표기):

```
지사 클라 ─┬─ path[0] ─► 릴레이 A ─────────────────────► 서버(지사 전용 프로세스)
           └─ path[1] ─► 릴레이 B ─► 릴레이 C ─────────► 서버(같은 프로세스)
다른 지사 ────────────► 릴레이 B ─► 릴레이 C ─────────► 서버(다른 호스트)
```

- **키가 곧 라우팅 식별자다.** 릴레이는 `--route "<key> <upstream>"` 으로 분기하므로
  **경로상의 모든 릴레이가 그 지사 PSK 를 보유**해야 한다. 지사를 추가할 때 릴레이마다
  `--route` 를 한 줄씩 늘리는 것을 빠뜨리기 쉽다(실제로 2단 릴레이에서 누락돼 있었다).
- 서버는 **지사당 프로세스 1개**(리슨 포트 분리) → mud 경로 32 상한은 무관(프로세스당 2슬롯).

### 7-가. 설정 변경은 3줄뿐이었다

v1.0.0 시절 유닛을 **수정 없이** v1.3.1 로 기동할 수 있다(client·server·relay·route 모드
4종을 sv1 루프백에서 실제 값으로 검증). 바꾼 것은 성능 튜닝 3줄뿐이다:

| 항목 | 전 → 후 | 근거 |
|---|---|---|
| `-f` | `20:5` → **`5:1,20:4`** | 지사당 약 1 Mbps 에서 그룹이 1 에 머물러 패리티 5 고정. duplicate 2경로까지 곱하면 회선 **약 12배** → 약 4배 |
| `--fec-timeout` | `5` → **`10`** | mode 1 은 원본 즉시 송신이라 대가는 복구 지연뿐(유휴 RTT +0.75 ms) |
| `--decode-buf` | `8000` → **`2000`** | 연결당 31.7 → 9.4 MB. 링은 개수로 축출하므로 지연차 300 ms 도 N≈650 |

유지해야 하는 값: `-k` · `--auth-interval` · `--mode` · `--mtu`(§6-나).

### 7-나. 무음 실패 함정 4개 — 전부 실측 재현했다

설정을 옮기거나 지사별로 이름을 바꿀 때 걸린다. **넷 다 로그로는 정상처럼 보인다.**

1. **`--path` 의 소스 IP 가 그 호스트에 없어도 오류 없이 뜬다.** `static path registered
   local=<없는 IP>` 가 그대로 찍히고 `sent QUIC Initial on N path(s)` 까지 나온다.
   경고 0건·에러 0건이며 증상은 "경로가 RUNNING 이 안 되고 report 가 0" 뿐이다.
   **호스트 이전 시 1순위 의심.** 회선이 하나면 `0.0.0.0` 이 안전하다.
2. **경로를 줄일 때 `DEST_B` 만 비우면 기동 거부.** `--path "0.0.0.0:"` 가 전달되어
   `error: --path format is local_ip:remote_ip:port` → exit 1. `ExecStart` 의 `--path`
   **줄 자체를 지워야** 한다(경로 1개 구성은 정상 기동).
3. **`EnvironmentFile` 은 값 뒤 `#` 를 주석으로 보지 않는다.** `DEST_A=<ip>:<port>  # 설명`
   이면 주석까지 값에 들어간다. 주소 파서가 포트 뒤를 무시해 **우연히** 동작하지만
   `ps`/`systemctl status` 가 지저분해지고 파서가 바뀌면 깨진다 → 주석은 값 위 줄로.
4. **`EnvironmentFile` 이 없으면 `Result: resources`** 로 실패하고 **multi-fec 로그가 한 줄도
   없다**(`Failed to load environment files`). 유닛을 지사별 이름으로 복제할 때 conf 파일명
   불일치로 발생. `journalctl -xeu <unit>` 가 유일한 단서다.

### 7-다. 허용 오차가 계층마다 다르다 — 무음 폐기의 정체

| 검증 | 주체 | 허용 |
|---|---|---|
| obfs HMAC 슬롯 | 릴레이·서버 | **±60초** (±1 슬롯, `--auth-interval 60`) |
| mud `timetolerance` | **서버만** | **30초** |

→ 시계가 **30~60초** 어긋나면 **릴레이는 통과시키고 서버만 조용히 버린다.** 역으로,
릴레이가 HMAC 을 통과시켰다면 **클라 시계는 ±60초 안**이라고 역추론할 수 있다 — 진단 시
시계 후보를 좁히는 데 쓸 수 있다.

### 7-라. 홉별 진단법 (이번에 실제로 쓴 것)

- **키 지문으로 홉 간 키 일치를 키 없이 대조한다.** v1.0.6+ 는 `route[i] key=kf:xxxxxxxx` 로
  찍으므로, 같은 지사 키는 **전 홉에서 같은 지문**이어야 한다. 다르면 그 경로는 조용히 폐기된다.
- **구버전 판별에도 쓰인다** — `route added: key=<평문>` 이 보이면 v1.0.6 이전이다.
  (`systemctl restart` 만으로는 버전이 바뀌지 않는다. 바이너리를 교체하지 않은 호스트를
  이 한 줄로 잡아냈다.)
- **릴레이 `new session` 의 시각을 홉마다 대조**하면 끊긴 구간이 초 단위로 특정된다.
  클라 기동 시각과 각 홉의 `new session` 이 초 단위로 일치하는 구간까지는 살아 있다.
- **대조군을 활용한다** — 같은 릴레이에서 다른 지사 경로가 정상이면 그 릴레이의 upstream
  송신 자체는 정상이다. 남는 차이는 목적지뿐이므로 목적지측 도달성으로 좁혀진다.
- 클라이언트의 `dropped N stale pending packet(s) (>1000 ms)` 가 반복되면 **경로가 없어
  큐가 버려지는 중**이다(v1.3.1 정상 동작). 경로가 살아나면 멈춘다.

### 7-마. 바이너리 — 태그 재빌드도 동등하다

배포본은 태그 빌드(`git v1.3.1`)를 썼고, §0 이 지정한 검증본(`git v1.3.0-19-g…-dirty`)과
**바이트는 202,860개 다르지만 명령어 시퀀스는 동일**하다(둘 다 245,377개, 니모닉 md5 일치).
검증 빌드 기반 커밋과 태그 사이에 커밋된 코드는 버전 문자열과 이번 수정뿐이고, 바이트 차이는
버전 문자열 길이(24자 → 6자)가 `.rodata` 주소를 밀어 명령어 피연산자까지 바꾼 결과다.

→ **§5-4 의 "검증본 md5 를 고수하라"는 이 경우 불필요하다.** 단 **호스트 간에는 한 빌드로
통일하고 md5 를 기록**할 것. 동등성을 주장하려면 위 니모닉 비교처럼 근거를 남겨야 한다.

### 7-바. 운영 확인 누락 — 전 호스트 유닛이 `disabled` 였다

작업 중 확인한 다섯 호스트가 **전부 `disabled`** 였다(수동 기동만 돼 있었다). 재부팅하면
체인이 올라오지 않는다 — 테스트망에서 2026-08-03 에 겪은 것과 같은 상태다. 적용 후
`systemctl is-enabled` 를 역할별로 반드시 확인할 것.
