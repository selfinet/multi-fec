# multi-fec 운영망 적용 체크리스트 (RS / mode1)

> 결정: **FEC 모드 = mode1(RS)** 로 적용한다. mode2(RNLC)는 다운스트림 throughput
> 문제(지연/재정렬로 TCP cwnd collapse, ~3Mbps 고착, 원인 미해결)로 **운영 보류**.
>
> 검증 근거(2026-06-19, 테스트망 s/c/r.xdn):
> - 10세션 3시간 아징: 누수 0 · cross-talk 0 · 크래시 0 · 전달 99.87%
> - 8시간 소크 완주(누수/크래시 0)
> - 다운스트림 FEC 복구: netem 15% 손실 → 수신 잔여손실 **0.006%**, TCP **12.0 Mbps**
> - RS는 MDS(임의 k개 수신 시 복구 보장), upstream lib/fec 다년 검증

---

## 1. 빌드 & 바이너리

- [ ] **wt5**(빌드 호스트)에서 `cd ~/multi-fec && make static-strip` → `multi-fec-dist`
- [ ] 배포 경로 **`/usr/sbin/multi-fec-dist`** (전 호스트 동일)
- [ ] mode1에는 신규 코드 변경 없음(dev의 Cauchy 패치는 mode2 전용·mode1 무영향) → 현
      검증 바이너리(md5 `3cf7d5c6…`) 또는 dev 최신 둘 다 mode1 동작 동일
- [ ] 배포 전 기존 바이너리 백업: `cp -a /usr/sbin/multi-fec-dist{,.bak-YYYYMMDD}`
- [ ] 전송 경로: wt5는 운영 호스트 직접 접근 불가 → wt5→로컬→각 호스트 scp

## 2. 설정 — 클라이언트/서버/릴레이 **반드시 일치**

- [ ] `KEY` = 강한 PSK, **server/client/relay 동일**
- [ ] `--mode 1`
- [ ] `-f 20:5` (손실률 따라 조정 가능 — §6 참고)
- [ ] `--fec-timeout 5` (대용량 위주면 8~20 검토)
- [ ] `--obfs-mode quic`
- [ ] **`--auth-interval` 동일값**(권장 60). ⚠️ 릴레이 포함 3자 모두 같아야 함 —
      불일치 시 HMAC이 **조용히 드롭**(증상 없이 무통신)
- [ ] `--mtu 1350` (WG MTU 1300 기준)
- [ ] `--multipath-mode` 환경에 맞게(단일경로=failover / 이중화=duplicate / 합산=aggregate)
- [ ] `--report 60` (초기 운영 모니터링용)

## 3. WireGuard / 네트워크

- [ ] **WireGuard MTU = 1300** (1420 방치 시 IP 단편화 → 처리량 ~37% 저하)
- [ ] WG peer **Endpoint = multi-fec client listen**(예 `127.0.0.1:51821`).
      multi-fec 미경유 직결 터널과 혼동 금지
- [ ] 서버 `--wg` = 로컬 WG listen 주소
- [ ] 멀티패스(소스 IP 2개 이상)면 **policy routing** 설정(소스별 라우팅 테이블/규칙)
- [ ] 방화벽: 외부 리슨 포트(예 :443 UDP) 허용

## 4. 배포 절차

- [ ] `/etc/multi-fec/{server,client,relay}.conf` + systemd `multi-fec-{server,client,relay}.service` 배치
- [ ] `systemctl daemon-reload`
- [ ] 기동 순서: **server → relay → client**
- [ ] (권장) unit에 `TimeoutStopSec=3` (SIGTERM 핸들러 없어 기본 90s 대기 회피)
- [ ] `systemctl enable --now multi-fec-<role>`

## 5. 적용 직후 검증

- [ ] 3개 서비스 `systemctl is-active` = active
- [ ] 터널 ping: `ping <상대 터널IP>` → 0% loss, RTT 합리적
- [ ] 다운스트림 처리량: `iperf3 -c <서버 터널IP> -R -t 20` (TCP) — 기준선 대비 확인
- [ ] 손실 검증: `iperf3 -c <서버 터널IP> -R -u -b <대역> -l 1200 -t 20` → 수신 손실%
      (UDP는 datagram 크기 고정 `-l 1200` 권장; 미지정 시 손실% 오판 가능)
- [ ] `--report` 로그에서 **`server-->client:(original:N pkt)` N>0** (양방향 흐름 확인)
- [ ] 로그 레벨 4로 경고/에러 없음 확인

## 6. 초기 운영 모니터링

- [ ] `--report 30~60` 으로 손실률·throughput 추적
- [ ] 서버/클라 프로세스 **RSS 추세**(누수 없는지) — 안정 시 평탄선
- [ ] 측정 손실률에 맞춰 `-f` 튜닝:
      | 링크 손실 | FEC | 오버헤드 |
      |---|---|---|
      | 1~3% | `20:2` | 10% |
      | 3~8% | `20:4` | 20% |
      | 8~15% | `20:7` | 35% |
- [ ] 참고: `-f 20:5`는 모든 세대 크기에 r=5 적용 → TCP 버스트로 작은 세대가 잦으면
      FEC 오버헤드 증가(fec/original 최대 ~2x). 기능 문제는 아니나 대역폭 효율 관점 인지

## 7. 롤백

- [ ] 백업 바이너리 복원: `install -m755 /usr/sbin/multi-fec-dist.bak-YYYYMMDD /usr/sbin/multi-fec-dist`
- [ ] 설정 원복 후 `daemon-reload` + `restart`
- [ ] 터널 재handshake 확인(ping)

## 8. 하지 말 것 (운영 금지)

- [ ] ❌ **mode2(RNLC) 운영 적용** — 다운스트림 throughput 미해결
- [ ] ❌ `--auth-interval` 3자 불일치
- [ ] ❌ WireGuard MTU 1420 방치
- [ ] ❌ 한 클라이언트 프로세스에서 다중 세션 기대(1프로세스=1세션; 세션 늘리려면 프로세스 추가)

---

## 참고

- 토폴로지·systemd 예시: `CLAUDE.md`(작업 워크플로 > 테스트 환경, CLI 옵션 레퍼런스)
- 배포 시나리오 예제: `DEPLOY_EXAMPLES.md`
- 측정 근거: `test-results/2026-06-19-multi-session/`
- mode2 보류 사유 상세: `test-results/2026-06-19-multi-session/downstream-fec/rnlc-decode-bottleneck-analysis.md`
