#!/usr/bin/env python3
"""rc_analyze.py — 릴레이 단절 구간 분석.

rc_probe.py 의 100ms 버킷 CSV 와 rc_run.sh 가 남긴 절단/복구 wall clock 을
맞춰서, 절체에 실제로 몇 ms 걸렸고 그동안 몇 개를 잃었는지 낸다.

  rc_analyze.py raw/rc_<tag>.csv raw/rc_<tag>.events
"""
import sys

csv_path, ev_path = sys.argv[1], sys.argv[2]

ev = {}
for line in open(ev_path):
    k, _, v = line.strip().partition("=")
    ev[k] = v

rows = []
t0_wall = None
marks = {}
for line in open(csv_path):
    line = line.strip()
    if line.startswith("#"):
        for tok in line.lstrip("# ").split():
            if tok.startswith("t0_wall="):
                t0_wall = float(tok.split("=", 1)[1])
            elif tok.startswith("mark") and "_ms=" in tok:
                k, v = tok.split("=", 1)
                marks[k] = float(v)
        continue
    if line.startswith("t_ms"):
        continue
    p = line.split(",")
    rows.append((int(p[0]), int(p[1]), int(p[2]), int(p[3]), int(p[4])))

# 절단·복구 위치는 **프로브가 자기 시간축에 남긴 마커**를 쓴다.
# sv1 에서 ssh 로 찍은 시각은 왕복 ~1s 가 그대로 오차가 되고(버킷은 100ms),
# ssh 세션 설정 때문에 오프셋 측정 자체가 +0.5s 편향된다(2026-08-03 실측).
axis = "마커(프로브 자체 시계)"
if "mark0_ms" in marks and "mark1_ms" in marks:
    cut_ms, res_ms = marks["mark0_ms"], marks["mark1_ms"]
else:
    axis = "t0_wall 산술 — ⚠️ 마커 없음, 호스트 간 시계차만큼 오차"
    cut_ms = (float(ev["t_cut"]) - t0_wall) * 1000
    res_ms = (float(ev["t_restore"]) - t0_wall) * 1000


def window(lo, hi):
    s = sum(r[1] for r in rows if lo <= r[0] < hi)
    r_ = sum(r[2] for r in rows if lo <= r[0] < hi)
    return s, r_, (100.0 * (s - r_) / s if s else 0.0)


def first_recovered(start_ms, need=3):
    """start_ms 이후 무손실 버킷이 need 개 연속 나오는 첫 시점"""
    run = 0
    for t, s, r, _, _ in rows:
        if t < start_ms:
            continue
        if s and r >= s:
            run += 1
            if run >= need:
                return t - (need - 1) * 100
        else:
            run = 0
    return None


print("=" * 66)
print("릴레이 단절 — %s   (절단 t=%.0fms, 복구 t=%.0fms)"
      % (ev.get("method", "?"), cut_ms, res_ms))
print("시간축 기준: %s" % axis)
if ev.get("r_after"):
    print("복구 후 r 상태: %s  (기대: active active 0)" % ev["r_after"].strip())
print("=" * 66)
print()
for name, lo, hi in [
        ("절단 전 (baseline)", 0, cut_ms),
        ("절단 직후 1초", cut_ms, cut_ms + 1000),
        ("절단 직후 3초", cut_ms, cut_ms + 3000),
        ("단절 지속 구간", cut_ms + 3000, res_ms),
        ("복구 직후 3초", res_ms, res_ms + 3000),
        ("복구 후 정상", res_ms + 3000, 10 ** 9)]:
    s, r, l = window(lo, hi)
    print("  %-20s sent=%-7d recv=%-7d 유실 %7.4f%%" % (name, s, r, l))

print()
# 절체 구간 상세 — 손실이 난 버킷만
bad = [(t, s, r) for t, s, r, _, _ in rows if cut_ms - 200 <= t <= cut_ms + 5000 and r < s]
if bad:
    print("  절단 전후 손실 버킷 (100ms):")
    for t, s, r in bad:
        print("    t=%+7.0fms  sent=%-4d recv=%-4d  (-%d)" % (t - cut_ms, s, r, s - r))
    gap = max(t for t, _, _ in bad) - min(t for t, _, _ in bad) + 100
    lost = sum(s - r for _, s, r in bad)
    print("  → 영향 구간 %.0fms, 유실 %d 패킷" % (gap, lost))
else:
    print("  절단 전후 손실 버킷 없음 — 무중단")

print()
rec = first_recovered(res_ms)
if rec is not None:
    print("  복구 후 정상화: t=%+.0fms (복구 명령 기준)" % (rec - res_ms))

# RTT 변화
def rtt_med(lo, hi):
    v = [r[3] for r in rows if lo <= r[0] < hi and r[3] > 0]
    return sorted(v)[len(v) // 2] / 1000.0 if v else -1


print()
print("  RTT p50: 절단전 %.1fms / 단절중 %.1fms / 복구후 %.1fms"
      % (rtt_med(0, cut_ms), rtt_med(cut_ms + 3000, res_ms), rtt_med(res_ms + 3000, 10 ** 9)))
