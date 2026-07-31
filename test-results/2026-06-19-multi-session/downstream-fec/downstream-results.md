# 다운스트림 FEC 복구 측정 (2026-06-19)

실제 WireGuard `starlink-fec` 터널(multi-fec 경유) 위에서 `iperf3 -R`(reverse =
서버→클라 = 다운스트림)로 측정. 다운스트림은 s.xdn ens19 egress의 netem
(delay 25±5ms, **loss 15±25%**)을 통과한다. FEC 20:5, 단일 세션.

- iperf3 서버: s.xdn `10.9.10.1` (fec 터널 내부 IP)
- iperf3 클라: c.xdn → `iperf3 -c 10.9.10.1 -R`
- 서버측 raw 로그: `iperf3-server.log`

## 결과

| 지표 | mode1 (RS) | mode2 (RNLC) |
|------|-----------|--------------|
| TCP goodput (다운스트림) | **12.0 Mbit/s** | **2.93 Mbit/s** |
| TCP retransmit | 257 | 203 |
| UDP `-b 8M` 수신 잔여손실 | **0.0062%** (1/16060) | **0.68%** (109/16062) |
| UDP out-of-order | 6,079 | 7,905 |

## 해석

- **FEC가 다운스트림 15% 손실을 실제로 복구함** — 두 모드 모두 netem 15% 손실을
  받고도 수신단 잔여손실이 mode1 0.006%, mode2 0.68%로 떨어짐.
- **RNLC(mode2)가 RS(mode1)보다 현저히 열세** — goodput ~4배 낮고(12.0→2.93Mbps),
  잔여손실 ~100배. 병목은 클라측(c.xdn) RNLC 가우스 소거 디코드.
- 이전 RNLC 아징의 처리량 저하(6.1 vs 2.46Mbps)와 일치하며 충실히 재현.

## 측정 raw 명령

```bash
# 서버 (s.xdn)
iperf3 -s -B 10.9.10.1
# 클라 (c.xdn) — 다운스트림(reverse)
iperf3 -c 10.9.10.1 -R -t 20            # TCP goodput
iperf3 -c 10.9.10.1 -R -u -b 8M -t 20   # UDP 손실%
```

> 주의: multi-fec 경유 WG는 `starlink-fec`(c.xdn endpoint=127.0.0.1:51821).
> `starlink-xdn`은 직결(공인:51820)이라 FEC 미경유 — 측정에 쓰면 안 됨.
> mode 전환은 `.service` ExecStart `--mode N` 하드코딩(FIFO는 mode2 미지원)이라
> sed+daemon-reload+restart 필요. 측정 후 mode1로 원복함.
