# multi-fec 8시간 에이징 소크 결과

- **기간**: 2026-06-18 01:40 → 09:41 KST (8.0h)
- **빌드**: `multi-fec-dist` (2026-06-18, sha256 `c57726ec…`, RNLC + get_str 수정 포함), `/usr/sbin/multi-fec-dist`
- **토폴로지**: Client `c.xdn` ─(path A→Relay `r.xdn` 192.168.100.85)─/─(path B→직결)─ Server `s.xdn` (218.154.1.134)
- **FEC/모드**: `--mode 1`(low-latency RS), `-f 20:5`, multipath `duplicate`, obfs quic, auth-interval 60
- **임페어먼트**: 릴레이 ens18 UDP/443에 `netem delay 25ms loss 15%` (RTT +50ms, 각 방향 15% 손실)
- **부하**: iperf3 최대 throughput 연속, 5분 up/down 교대 (터널 10.9.10.2 ↔ 10.9.10.1)

## 판정 — ✅ 합격 (이상 0건)

| 항목 | 결과 | 비고 |
|---|---|---|
| 메모리 누수 | ❌ 없음 | 워밍업 후 평탄, 8h 추가 증가 0 |
| fd 누수 | ❌ 없음 | 전 구간 단일값 |
| 크래시/재시작 | ❌ 없음 | PID 불변, restarts=0, 490샘플 active |
| throughput 저하 | ❌ 없음 | 96세그먼트 일정 |

## 노드별 지표 (시작 → 종료)

| 노드 | RSS (KB) | fd | PID | restarts | active |
|---|---|---|---|---|---|
| server (s) | 33876 → 36204 (워밍업 후 평탄) | 8 (불변) | 1900220 (불변) | 0 | 전 구간 |
| client (c) | 34148 → 38084 (워밍업 후 평탄) | 8 (불변) | 409379 (불변) | 0 | 전 구간 |
| relay (r) | 1676 (전 구간 불변) | 16 (불변) | 695034 (불변) | 0 | 전 구간 |

RSS 고유값 궤적: server `33876→34884→35676→35940→36204`(첫 1h), client `34148→36752→37280→37808→38084`(첫 1h) — 이후 종료까지 변화 없음 → 누수 아님.

## throughput (96 세그먼트 = 48 UP + 48 DOWN, 각 300초)

| 방향 | 평균 | min | max |
|---|---|---|---|
| UP (client→server) | 40.2 Mbps | 39.9 | 40.4 |
| DOWN (server→client) | 6.1 Mbps | 5.81 | 6.45 |

손실 15% 환경에서도 8h 내내 양방향 처리율 일정 (duplicate 멀티패스 복원력).

## 종료 후 정리
- transient 유닛 정지: mf-aging-load, mf-aging-mon(s/c/r), iperf3srv, mf-aging-cleanup
- 릴레이 netem 제거 → fq_codel 복귀
- 정규 multi-fec-{server,client,relay} active 확인, 터널 ping 0% 손실·RTT ~28ms 정상

## 동봉 원본 로그
- `server_mon.log` / `client_mon.log` / `relay_mon.log` — 60초 간격 RSS/fd/cpu/restarts/active (각 490샘플)
- `client_load.log` — iperf3 세그먼트별 throughput (96세그먼트)
