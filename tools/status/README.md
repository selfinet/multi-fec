# tools/status — multi-fec 상태 웹페이지 (1단계, 테스트망 전용)

> ⚠️ **실서비스망에는 적용하지 않는다** (2026-10-19 결정). 개발은 sv1 루프백, 실측은 테스트망까지.

```
각 호스트 mf_agent.py ──30초 push(JSON, 호스트 토큰)──▶ mf_status.py (SQLite·규칙) ──▶ 브라우저 대시보드
```

| 파일 | 역할 |
|---|---|
| `mf_agent.py` | 호스트에서 유닛·경로·세션·자원 수집 → `POST /api/push`. 읽기 전용(systemctl·journalctl·/proc·ss·wg). root 로 실행 |
| `mf_status.py` | 중앙 서버. 저장(7일)·규칙·이벤트(30일)·API·대시보드. 표준 라이브러리만 |
| `dashboard.html` | 단일 페이지. 10초마다 갱신, 숫자를 누르면 추이 그래프 |

## 테스트망 설치 현황 (2026-10-19, 2단계)

| 호스트 | 유닛 | 파일 |
|---|---|---|
| s `192.168.100.102` | `mf-status`(중앙, `192.168.100.102:8780`) | `/opt/mf-status/` · `/etc/mf-status/{tokens,status.env,labels}`(600) · `/var/lib/mf-status/status.db` |
| r `.88` | `mf-agent` (**수집은 relay 에서만**, 2026-10-19) + `mf-nftstat`(세션 구간 카운터) | `/opt/mf-status/mf_agent.py` · `/etc/mf-status/agent.env`(600, URL+토큰) · `/etc/mf-status/mfstat.nft` |
| c `.92` · s | `mf-agent` 설치돼 있으나 **disabled** | 토큰은 s `tokens.bak-all` 에 보관 — 다시 켜려면 tokens 에 줄을 되돌리고 `mf-status` 재시작 |

에이전트는 WG 터널이 아니라 하부망(`.102`)으로 보낸다 — 터널이 죽어도 보고가 끊기지 않아야 하므로.
보기: sv1 경유 `ssh -p 2234 -N -L 8780:192.168.100.102:8780 <계정>@sv1` → http://localhost:8780 (sv1 에는 아무것도 띄우지 않는다).
되돌리기: 각 호스트 `systemctl disable --now mf-agent`(s 는 `mf-status` 도) → `/opt/mf-status` `/etc/mf-status` `/var/lib/mf-status` 삭제,
`/etc/systemd/system/mf-{agent,status}.service` 삭제 후 `daemon-reload`.

## 실행

```bash
# 중앙 (토큰 파일: 한 줄에 "호스트명 토큰", 권한 600)
python3 mf_status.py --listen 127.0.0.1:8780 --db status.db --tokens tokens

# 호스트 (hostname 이 토큰 파일의 호스트명과 같아야 한다)
MF_AGENT_TOKEN=<토큰> python3 mf_agent.py --url http://<중앙>:8780

# 시험 — push 없이 출력
python3 mf_agent.py --once
```

## relay 만으로 보는 것 (relay 기준 화면)

지사 고객 장비(c·s)에 설치하지 않고 relay 에만 에이전트를 둘 때 쓰는 화면이다.

| 보이는 것 | 출처 |
|---|---|
| **구성도** — 지사 ⇄ relay ⇄ server SVG. 선 = 세션, 선 위 = 지사 주소·relay 소스와 **커널이 실제로 고르는 송신 NIC**, relay 칸 = 리슨 NIC vs 송신 NIC(다르면 주황 "NIC 불일치")·NIC Mbps, 빨간 점선 = 지사 이탈 | 세션 표 + `ss` 리슨 주소 + `ip route get <목적지> from <소스>`(5분 캐시) |
| 지사 × relay 표 — 지사(키 지문, `labels` 로 이름) 가 어느 relay 를 지나는지, 세션 주소·지속 시간 | 로그 `[relay] new session`/`session removed`(커서로 이어 읽음) + 그 fd 가 지금 열린 upstream 소켓인지 `ss` 로 확인 |
| 경로 끊김 경보 — 늘 보이던 relay 에서 그 지사 세션이 **2분** 이상 없음 | relay 는 60초 무통신 세션을 지우므로 "없음" = 최소 1분 이상 끊김. 24시간 안 보이면 감시 해제 |
| 세션 생성·종료 · 프로브(인증 실패) · 세션 테이블 포화 이벤트 | 프로브는 `--decoy` 를 쓸 때만 info 로그가 남는다(내장 응답은 debug) |
| relay 자원 · 버전 · 키 지문 · 재시작 | `/proc`, 기동 로그 |
| **NIC 별 물리 트래픽** — Mbps·pps·드롭(rx/tx/qdisc 구간 증가)·오류·상태·주소·누적량, 누르면 추이 | `/proc/net/dev` 차분, `/sys/class/net`, `tc -s qdisc`. NIC down → crit, 오류 증가 → warn |

NIC 드롭 읽는 법(테스트망 r 실측): RX 드롭이 NIC 마다 초당 ~2 씩 꾸준히 오른다 — 커널이 처리하지 않는 프레임(LAN 브로드캐스트 등)이 대부분이라
**증가 속도가 바뀔 때**만 본다. qdisc 드롭은 테스트망에선 netem 이 흉내 낸 손실이다(서비스망엔 netem 이 없으니 0 이어야 정상).
ens19 TX 가 0 인 것은 결함이 아니라 라우팅이 ens18 을 고르기 때문(§30) — `via` 를 쓰면 바뀐다.

**세션 구간 트래픽 (nft, 2026-10-19)**: UDP 소켓에는 바이트 카운터가 없어 relay 호스트에 `nft/mfstat.nft`(테이블 `inet mfstat`, **세기만 하고 전부 accept**)를 둔다.
동적 집합 4개 — client 구간은 `client IP . 포트 . relay IP`, server 구간은 `relay 소스 IP . 포트` 키. 에이전트가 세션 표로 이어 붙여 c→r · r→s · s→r · r→c Mbps/pps 를 낸다.
테이블이 없으면 트래픽 칸만 비고 나머지는 그대로 동작한다. 리슨 포트가 443 이 아니면 파일의 `LISTEN` 을 고친다. 리슨이 `0.0.0.0` 이면 같은 client 주소 항목을 합친다.
**구간 경보**: client→relay 가 들어오는데 server→relay 가 0 인 상태가 60초 넘으면 crit ("응답 없음") — relay↔server 구간 문제를 가린다.
검증(테스트망 r): 세션 4방향 합이 ens18 TX 와 일치(0.199 vs 0.2 Mbps), c→r 과 r→s 가 패킷·바이트까지 동일(relay 는 그대로 넘긴다).
되돌리기: `systemctl disable --now mf-nftstat`(정지 시 테이블 삭제) → 유닛·`mfstat.nft` 삭제.

**못 보는 것**: 경로 owd·loss(client 로그에만 있다).
`labels` 파일: 한 줄에 `kf:xxxxxxxx 지사이름`.

## 무엇을 보내나 · 안 보내나

- 보냄: 유닛 상태·PID·재시작 수, 버전, CPU%·RSS·FD, 소켓 drops, relay 세션 수, client 경로(상태·owd·loss·tx/rx·dev),
  report 카운터, 호스트 load·메모리·트래픽·UDP 오류·NTP·WireGuard 핸드셰이크 나이, **키 지문(kf:)**
- 안 보냄: **키**. 명령줄의 `-k`/`--key`/`--route` 값은 `****` 로 가린다(1.3.x 는 argv 에 키가 평문이다).

## 경보 규칙

| 규칙 | 수준 |
|---|---|
| 에이전트 보고 90초 끊김 | crit |
| 유닛 정지 | crit |
| client 경로가 RUNNING 아님 2분 이상 | crit |
| 재시작(PID 변경, 버전 변화 표시) · 소켓 drops 증가 · 로그 ERROR 증가 · UDP 수신 버퍼 넘침 증가 | warn (이벤트) |
| NTP 미동기 · WireGuard 핸드셰이크 3분 초과 · 에이전트 시계 ±10초 | warn |
| 호스트 간 버전 혼재 | info |

## 한계

- GET API·대시보드는 인증이 없다 → 루프백이나 신뢰 구간에만 연다(외부에 열려면 리버스 프록시 인증).
- relay 는 자체 통계가 없어 트래픽은 **호스트 인터페이스 합계**다(relay 전용 호스트면 거의 relay 몫).
- 1.3.x client 는 owd 대신 옛 `rtt=..us` 표기라 지연 칸이 빈다(상태·loss 는 나온다).
- 키 지문(kf:)은 1.4.0 부터 기동 로그에 남는다 — 1.3.x 는 비어 있다.
