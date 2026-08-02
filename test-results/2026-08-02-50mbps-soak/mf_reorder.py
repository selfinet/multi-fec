#!/usr/bin/env python3
"""
mf_reorder.py — 터널 위 단방향 UDP 재정렬·손실 측정 (자체 시퀀스 기준)

왜 만들었나
-----------
iperf3 `--bidir` 의 역방향(RX-C) 계수는 신뢰할 수 없다. 같은 로그에 `-1/12499` 같은
**음수 손실**이 찍히고, 2026-08-02 소크 청크4 에서는 재정렬이 47,000 → 561,216 으로
12배 튀었는데 손실·ping·gw·경로 상태 어디에도 대응 이상이 없었다. 계수 자체를 못 믿어
"문제 없음"을 확정하지 못한 채 과제로 남겼다(REPORT.md §4).

재정렬은 duplicate 경로 지연차의 구조적 부산물이라 상시 발생하고, TCP 에는 실제 영향이
간다(spurious fast retransmit → cwnd 붕괴). 관측 수단이 없으면 이 축을 볼 수 없다.

설계
----
- **단방향**. 양방향으로 섞으면 어느 방향의 재정렬인지 구분이 안 되고, iperf3 가 틀린
  것도 역방향 계수였다. 방향을 나눠 각각 돌린다.
- **자체 시퀀스**. 페이로드 앞 8바이트에 시퀀스를 박고 수신측이 직접 판정한다.
  중간 계층(iperf3)의 해석에 의존하지 않는다.
- **재정렬의 정의를 명시**한다. "직전 최대 시퀀스보다 작게 도착"(iperf3 의 정의)과
  **변위(displacement)** 를 함께 낸다. 전자는 한 번 크게 튀면 이후가 전부 재정렬로
  집계돼 과대평가된다 — 561,216 같은 값이 나오는 경로다.

사용
----
  수신측(s):  ./mf_reorder.py recv --bind 10.9.10.1:5301
  송신측(c):  ./mf_reorder.py send --to 10.9.10.1:5301 --mbps 6 --secs 60
  수신측이 종료 시 요약을 stdout 에 JSON 으로 낸다 (--json 없으면 사람이 읽는 표).
"""
import argparse, json, socket, struct, sys, time

MAGIC = b"MFRO"
HDR = struct.Struct("!4sQd")          # magic, seq, send_ts


def send(args):
    host, port = args.to.rsplit(":", 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, 4 << 20)
    dst = (host, int(port))

    pay = args.size - HDR.size
    if pay < 0:
        sys.exit(f"--size 는 최소 {HDR.size} 이상")
    filler = bytes(pay)

    pps = args.mbps * 1_000_000 / 8 / args.size
    gap = 1.0 / pps
    end = time.time() + args.secs
    seq = 0
    nxt = time.time()
    while time.time() < end:
        s.sendto(HDR.pack(MAGIC, seq, time.time()) + filler, dst)
        seq += 1
        nxt += gap
        d = nxt - time.time()
        if d > 0:
            time.sleep(d)
        elif d < -0.5:                # 뒤처지면 페이스를 다시 잡는다(무한 추격 방지)
            nxt = time.time()
    # 수신측이 종료를 알 수 있도록 종료 표식을 여러 번 (유실 대비)
    for _ in range(20):
        s.sendto(HDR.pack(MAGIC, 2**64 - 1, time.time()) + filler, dst)
        time.sleep(0.01)
    print(f"보냄 {seq} 패킷 ({args.mbps} Mbps, {args.size}B, {args.secs}s)")


def recv(args):
    host, port = args.bind.rsplit(":", 1)
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 8 << 20)
    s.bind((host, int(port)))
    s.settimeout(args.timeout)

    got = set()
    n = dup = 0
    late = 0                 # iperf3 정의: 직전 최대보다 작게 도착
    disp_sum = disp_max = 0  # 변위: (직전 최대 - 이 시퀀스). 실제로 얼마나 밀렸나
    hi = -1
    owd_min = None
    first = last = None

    while True:
        try:
            data, _ = s.recvfrom(65535)
        except socket.timeout:
            break
        if len(data) < HDR.size:
            continue
        magic, seq, ts = HDR.unpack(data[:HDR.size])
        if magic != MAGIC:
            continue
        if seq == 2**64 - 1:
            break
        now = time.time()
        if first is None:
            first = now
        last = now

        if seq in got:
            dup += 1
            continue
        got.add(seq)
        n += 1

        if seq < hi:
            late += 1
            d = hi - seq
            disp_sum += d
            disp_max = max(disp_max, d)
        else:
            hi = seq

        owd = now - ts       # 시계가 동기화돼 있지 않으면 절대값은 무의미 —
        if owd_min is None or owd < owd_min:
            owd_min = owd    # 최소값을 기준선으로 삼아 지연 변동만 본다

    sent = hi + 1 if hi >= 0 else 0
    lost = sent - n
    out = {
        "sent_추정": sent,          # 최대 시퀀스 기준. 꼬리 유실은 안 잡힌다
        "received": n,
        "lost": lost,
        "loss_pct": round(lost * 100.0 / sent, 6) if sent else 0.0,
        "dup": dup,
        "reordered_late": late,                     # iperf3 와 같은 정의
        "reordered_pct": round(late * 100.0 / n, 4) if n else 0.0,
        "displacement_avg": round(disp_sum / late, 2) if late else 0,
        "displacement_max": disp_max,
        "duration_s": round(last - first, 2) if first else 0,
    }
    if args.json:
        print(json.dumps(out, ensure_ascii=False))
    else:
        print(f"  수신           {out['received']:,} / 추정 송신 {out['sent_추정']:,}")
        print(f"  손실           {out['lost']:,} ({out['loss_pct']}%)")
        print(f"  중복           {out['dup']:,}")
        print(f"  재정렬         {out['reordered_late']:,} ({out['reordered_pct']}%)"
              f"  ← iperf3 와 같은 정의")
        print(f"  변위 평균/최대  {out['displacement_avg']} / {out['displacement_max']}"
              f"  ← 실제로 몇 칸 밀렸나")
        print()
        print("  변위를 함께 보는 이유: '직전 최대보다 작게 도착' 정의는 시퀀스가 한 번")
        print("  크게 튀면 이후가 전부 재정렬로 집계돼 과대평가된다. 변위가 1~2 로 작으면")
        print("  경로 지연차에 의한 정상적인 인터리브이고, 크면 진짜 순서 붕괴다.")


ap = argparse.ArgumentParser(description=__doc__,
                             formatter_class=argparse.RawDescriptionHelpFormatter)
sub = ap.add_subparsers(dest="cmd", required=True)

sp = sub.add_parser("send")
sp.add_argument("--to", required=True, help="ip:port")
sp.add_argument("--mbps", type=float, default=6)
sp.add_argument("--secs", type=int, default=60)
sp.add_argument("--size", type=int, default=1200)
sp.set_defaults(fn=send)

rp = sub.add_parser("recv")
rp.add_argument("--bind", required=True, help="ip:port")
rp.add_argument("--timeout", type=float, default=10, help="무수신 종료 대기(초)")
rp.add_argument("--json", action="store_true")
rp.set_defaults(fn=recv)

a = ap.parse_args()
a.fn(a)
