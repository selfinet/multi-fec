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
| r `.88` | `mf-agent` (**수집은 relay 에서만**, 2026-10-19) | `/opt/mf-status/mf_agent.py` · `/etc/mf-status/agent.env`(600, URL+토큰) |
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
| 지사 × relay 표 — 지사(키 지문, `labels` 로 이름) 가 어느 relay 를 지나는지, 세션 주소·지속 시간 | 로그 `[relay] new session`/`session removed`(커서로 이어 읽음) + 그 fd 가 지금 열린 upstream 소켓인지 `ss` 로 확인 |
| 경로 끊김 경보 — 늘 보이던 relay 에서 그 지사 세션이 **2분** 이상 없음 | relay 는 60초 무통신 세션을 지우므로 "없음" = 최소 1분 이상 끊김. 24시간 안 보이면 감시 해제 |
| 세션 생성·종료 · 프로브(인증 실패) · 세션 테이블 포화 이벤트 | 프로브는 `--decoy` 를 쓸 때만 info 로그가 남는다(내장 응답은 debug) |
| relay 자원 · 버전 · 키 지문 · 재시작 | `/proc`, 기동 로그 |

**못 보는 것**: 세션별 트래픽 양(UDP 소켓에는 바이트 카운터가 없다 — nft 카운터 등 호스트 설정이 필요), 경로 owd·loss(client 로그에만 있다).
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
