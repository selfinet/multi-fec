#!/usr/bin/env python3
"""analyze_pend.py — pending 큐 TTL 검증 분석.

핵심 질문: 단절이 끝난 직후 **묵은 패킷이 배달되는가.**
2026-09-09(v1.3.0)에서는 복구 후 첫 응답 RTT 가 26,574 ms 였고 이후 프로브
간격(204 ms)씩 감소했다 — 단절 중 쌓인 약 130개가 FIFO 로 배출된 흔적이다.
v1.3.1 은 1초 초과분을 전송 전에 버리므로 이 꼬리가 없어야 한다.
"""
import os, re, sys

D = os.path.dirname(os.path.abspath(__file__))
LAB = sys.argv[1] if len(sys.argv) > 1 else "v131"
ping = os.path.join(D, f"pend_{LAB}_ping.log")
ev = os.path.join(D, f"pend_{LAB}_events.log")

R = re.compile(r"\[(\d+\.\d+)\].*icmp_seq=(\d+).*time=([\d.]+) ms")
rep = [(float(a), int(b), float(c)) for a, b, c in R.findall(open(ping, errors="replace").read())]
events = [(float(l.split()[0]), " ".join(l.split()[1:]))
          for l in open(ev, errors="replace").read().splitlines() if l.strip()]
rec = [t for t, m in events if "복구" in m]
stop = [t for t, m in events if "정지" in m]

print(f"=== {LAB} · 응답 {len(rep)}개 · 사이클 {len(rec)}개 ===")
STALE = 1000.0
for i, t in enumerate(rec, 1):
    after = [r for r in rep if r[0] >= t][:60]
    if not after:
        print(f"  cycle{i}: 복구 후 응답 없음"); continue
    stale = [r for r in after if r[2] > STALE]
    # 단절 구간의 연속 공백: 정지 시각 이후 첫 응답까지
    st = stop[i - 1] if i - 1 < len(stop) else t
    gap_end = after[0][0]
    prev = [r for r in rep if r[0] <= st]
    gap = gap_end - (prev[-1][0] if prev else st)
    print(f"  cycle{i}: 단절 공백 {gap:5.1f}s · 복구 후 첫 RTT {after[0][2]:8.1f} ms · "
          f"max(60개) {max(r[2] for r in after):8.1f} ms · "
          f"**{STALE:.0f}ms 초과 응답 {len(stale)}개**")
    if stale:
        print(f"        묵은 응답 RTT: {[round(r[2]) for r in stale[:8]]} …")

cli = os.path.join(D, f"pend_{LAB}_client.log")
if os.path.exists(cli):
    txt = open(cli, errors="replace").read()
    dropped = re.findall(r"dropped (\d+) stale pending packet", txt)
    flushed = re.findall(r"flushed (\d+) pending packet", txt)
    print(f"\n  클라 로그: stale 폐기 {len(dropped)}회 (합 {sum(map(int, dropped))}개) · "
          f"flush {len(flushed)}회 (합 {sum(map(int, flushed))}개)")

rss = os.path.join(D, f"pend_{LAB}_rss.log")
if os.path.exists(rss):
    print("\n  클라이언트 자원 (PID 기준):")
    for l in open(rss).read().splitlines():
        print("   ", l)
