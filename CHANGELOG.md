# 변경 이력 (CHANGELOG)

multi-fec의 **버전·작성일자별 변경 내용**을 기록한다. 버전별로 무엇이 언제 바뀌었는지 비교하기 위한 문서다.

## 기록 규칙

- 버전은 `common.h`의 `MULTI_FEC_VERSION`(semantic versioning)과 **항상 일치**시킨다.
- 변경 성격에 따라 버전을 올린다:
  | 변경 성격 | 버전 증가 | 예 |
  |-----------|-----------|-----|
  | 와이어 포맷·프로토콜·비호환 변경 | **MAJOR** (`x.0.0`) | obfs 헤더 구조 변경, 세션 포맷 변경 |
  | 기능 추가(하위 호환) | **MINOR** (`0.x.0`) | 새 `--mode`, 새 멀티패스 모드, 새 CLI 옵션 |
  | 버그 수정(동작 영향) | **PATCH** (`0.0.x`) | RNLC Cauchy 교체, mud window 고갈 수정 |
  | 문서·테스트·주석만 | **버전 유지** | `[Unreleased]`에 날짜 항목만 누적 |
- 각 항목은 날짜(`YYYY-MM-DD`)와 커밋 SHA를 함께 남긴다.
- 분류 태그: `추가`(신기능) · `변경`(기존 동작 변경) · `수정`(버그) · `문서/테스트`(비기능).
- 상세 배경·원인·측정치는 `CLAUDE.md`의 "버그 수정 이력" 섹션(§번호)에 두고, 여기서는 요약 + 참조만 남긴다.
- 버전을 올릴 때: ① `common.h`의 `MULTI_FEC_VERSION` 갱신 → ② 아래에 새 버전 섹션 추가 → ③ `[Unreleased]` 항목을 그 섹션으로 이동.

---

## [Unreleased]

_다음 릴리스에 포함될 변경. 문서/테스트만 바뀐 경우 여기에 날짜별로 누적한다._


---

## [1.0.1] — 2026-07-31

소스 리뷰에서 제기된 결함 8건을 코드로 검증해, 사실로 확인되고 자체 코드에 속하는 3건을 수정했다.
**세 수정 모두 수신측·서버 내부 로직만 바꿔 와이어 포맷은 무변경** — 구버전과 양방향 호환된다
(교차 조합 16종 실측 100% 전달: 신규/수정전/운영배포본 × server/client × failover/duplicate).

### 2026-07-31 (`d3c23fc`, 머지 `dda0f88`)
- **수정** — **mud dedup 오탐으로 정상 패킷이 폐기되던 문제.** 판정 키가 패킷 타임스탬프 단독이었는데,
  `MUD_TIME_MASK`가 bit0을 MSG 플래그로 쓰는 탓에 타임스탬프 해상도가 2µs여서 FEC 그룹 flush 같은
  버스트에서 **서로 다른 패킷이 중복으로 오판**됐다. 복제가 없는 failover/aggregate에서도 발생.
  키를 `(타임스탬프, 페이로드 해시)`로 바꾸고 테이블을 128엔트리 링버퍼 → **1024엔트리 직접사상**으로 교체
  (패킷당 128회 선형탐색 제거).
  실측: 계측 빌드에서 dedup 폐기 **160건 → 0건**, 0.2ms 간격 손실 1.40% → 0.00%. → CLAUDE.md §18-가.
- **수정** — **서버 세션 테이블 무한 증가.** `g_session_to_addr`에 만료·상한이 없어, 유효 토큰 보유자가
  무작위 `session_id`를 주입하면 메모리가 무제한 증가하고 공격 없이도 클라이언트 재시작마다 누적됐다.
  `last_seen` 기반 5분 만료(30초 주기 sweep) + `max_conn_num × 4` 상한과 LRU 축출 추가. → CLAUDE.md §18-나.
- **수정** — **obfs `pkt_type` 필드 손상.** `p[0] = 0x40 | (token[0] & 0x3F) | (pkt_type << 4)`에서
  토큰 비트 4-5와 `pkt_type`이 겹쳐 디코더가 DATA를 PROBE/PAD로 오분류했다. 소비처가 없던 필드라
  와이어 바이트에서 제거하고 디코더는 DATA를 반환(TLS 경로와 동일). 인증에 쓰이는 `token[0]`은
  `p[8]`에 원본 그대로 실려 검증되므로 구버전 영향 없음. → CLAUDE.md §18-다.
- 문서/테스트 — `OPTIONS.md` `--multipath-mode` 표에 누락돼 있던 `aggregate` / `aggregate-duplicate`
  추가, dedup 동작 설명을 수정 내용에 맞춰 갱신, FIFO 미지원·서버측 동일 설정 필요 주의 추가.

### 이번 릴리스에서 다루지 않은 항목
리뷰 지적 중 나머지는 ① 사용자가 수정을 거절한 사안, ② `fec_manager.cpp` / `packet.cpp` 등
**upstream(UDPspeeder) 코드**라 "upstream 미수정" 원칙과 충돌, ③ 기본 설정에서 발현되지 않아
설계 판단이 선행되어야 하는 사안으로 나뉜다. **이 리포는 공개 저장소이므로 미수정 항목의
위치·조건은 여기에 적지 않는다** — 상세는 리포 밖 내부 기록 참조. → CLAUDE.md §18-라.

### 리뷰 지적 중 사실과 달랐던 것
- "dedup 링 크기를 128로 상향" — `MUD_DEDUP_SIZE`는 **이미 128**이었다. 다만 고 pps에서 링이
  5.6ms마다 순환해 의도한 500ms 창이 축소되는 별개 문제가 있었고, 이번 1024 직접사상 교체로 해소.
- "`MUD_TIME_MASK`의 LSB 제거는 결함" — bit0은 `MUD_MSG` data/probe 플래그로 쓰이는 glorytun 설계다.
  따라서 처방은 마스크 수정이 아니라 판정 키 보강이 맞다.
- "판정 키를 `pkt_time + 시퀀스`로 변경" — 시퀀스는 와이어 포맷 변경이라 구버전 호환이 깨진다.
  페이로드 해시로 대체해 수신측만 바꿨다.

- 문서/테스트 · 2026-07-17 (`1cfa235`) — `CHANGELOG` 기록 규칙 예시 정비, `origin/dev`에 push.
- 문서/테스트 · 2026-07-09 (`7af99db`) — `CLAUDE.md`: sv1이 현재 셸이 도는 머신 자체(localhost, `ssh sv1` 거부)임을 명시, `--version` 표기 방식 문서화.
- 문서/테스트 · 2026-07-09 — `CHANGELOG.md` 신설: 버전·날짜별 변경 이력 관리 시작.

---

## [1.0.0] — 2026-07-02

첫 semantic 버전. `MULTI_FEC_VERSION` 매크로 도입 시점의 상태를 `1.0.0`으로 고정.
2026-06-15 최초 커밋부터 이 날까지의 모든 기능·수정을 포함한다(아래 날짜별 상세).

### 2026-07-02 (`40f9eef`)
- 변경 — 소스 내 한글 주석/문자열을 영어로 전환(동작 무변경).
- 추가 — `MULTI_FEC_VERSION "1.0.0"`(`common.h`) 도입, `--version` 표기 정비(버전 + git 리비전 + 빌드시각).
- 변경 — `Makefile` `git_version`이 `git describe --tags --dirty --always`로 실제 git 리비전을 기록(기존 `"local-build"` 하드코딩 제거).

### 2026-06-24 (`0a63fd5`, `96b04f6`)
- 문서/테스트 — 10세션 3시간 아징 드라이버(`run_aging_3h.sh`, mode1 90m + mode2 90m) 추가, `.gitignore` 보강.

### 2026-06-19
- **수정 (`ec9960b`)** — RNLC(mode 2) 코딩 계수를 **랜덤 → Cauchy 행렬(MDS)**로 교체.
  손실 ≤ r이면 임의 k개 수신 시 항상 복구(RS와 동등), 랜덤 계수의 rank 결핍(~0.4% 복구 실패) 제거. 디코더 무변경. → CLAUDE.md §17.
  ⚠️ **처리량 개선 아님**: 재측정 결과 mode2 다운스트림 TCP 2.5~3.0 Mbps로 격차 미해소(가설 검증 실패). 정확성(MDS) 개선일 뿐.
- 문서/테스트 (`66c6c31`, `841c743`, `73dee3f`, `3e15bd5`, `7ae2f72`, `6c800bc`, `5fd9590`, `e8c6325`) —
  다중 세션 스케일/아징 하베스트(`test_scale_sessions.py`) + RT 다운스트림 측정법 추가,
  RNLC mode2 다운스트림 격차 분석(CPU 병목 가설 데이터로 기각 → 지연/재정렬 한계),
  RS(mode1) 운영망 적용 체크리스트(`PRODUCTION_CHECKLIST.md`), 2026-06-18 아징 결과 `test-results/` 이동.

### 2026-06-18
- **수정 (`1941a24`)** — `address_t::get_str()` 회전 정적 버퍼로 교체 → 한 `mylog()`에서 다중 호출 시 주소 표기 뒤섞임 버그 수정. → CLAUDE.md §2.
- 문서/테스트 (`0728d72`, `7958fdf`) — 릴레이 systemd 템플릿/`relay.conf`에 `--auth-interval` 추가 및 불일치 경고, 8h 아징 소크 결과 추가.

### 2026-06-17 (`838cfb4`)
- **추가** — **RNLC(Random Linear Network Coding) FEC 모드 `--mode 2`**. GF(256) systematic 블록 코딩, RS와 동일한 `-f x:y`. → CLAUDE.md §16.

### 2026-06-15 (`311066e` 외)
- **추가** — 최초 릴리스. UDPspeeder V2 FEC + glorytun mud_lite 멀티패스 + GFW 난독화 결합 UDP 프록시.
  - FEC 모드 0(bandwidth-saving)/1(low-latency, RS)
  - 멀티패스: failover / duplicate / **aggregate** / **aggregate-duplicate** (mud_lite)
  - obfs: QUIC/TLS 위장 + SipHash HMAC 인증, QUIC Initial 핸드쉐이크 시뮬레이션, 내장 QUIC Server Initial 응답
  - 릴레이: 단일 upstream / 키별 라우팅(`--route`), decoy 지원
  - session_id 다중 POP 집계, FIFO 런타임 커맨드, TOTP 포트 호핑
  - mud_lite 치명적 수정 다수 포함: timetolerance/keepalive 단위(§1), window 고갈(§4), tx.loss LOSSY 탈출(§5), duplicate 모드(§6)
  - LICENSE + 서드파티 고지, auto-merge 워크플로 정책, timetolerance 30s 문서 동기화
