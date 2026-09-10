#!/usr/bin/env python3
"""cmp_v130.py — v1.3.1 과 v1.3.0 의 자원 궤적을 **경과시간 정렬**로 비교.

왜 필요한가: RSS 램프가 30분보다 길다(09-02 런에서 c 는 37.8분까지 계단이 이어졌다).
그래서 30분 창에서는 "마지막 변화 이후 평탄 구간" 판정이 성립하지 않는다.
대신 **같은 하네스·같은 세션 수·같은 레이트**로 돈 v1.3.0 런(2026-09-02)의 같은
경과시간 값과 비교한다. 궤적이 겹치면 이번 변경이 새 누수를 넣지 않았다는 뜻이다.
(v1.3.0 런은 60분이므로 앞 30분만 쓴다.)
"""
import csv, os, sys

D = os.path.dirname(os.path.abspath(__file__))
NEW = os.path.join(D, sys.argv[1] if len(sys.argv) > 1 else "wg_raw")
OLD = os.path.join(D, "..", "2026-09-02-multisession", "wg_raw")
import statistics as st


def series(path):
    rows = [r for r in csv.DictReader(open(path)) if r.get("t")]
    if not rows:
        return []
    mode = st.mode([int(r["nproc"]) for r in rows])
    keep = [r for r in rows if int(r["nproc"]) == mode]
    t0 = int(keep[0]["t"])
    return [(int(r["t"]) - t0, int(r["rss_kb"]) / 1024.0, float(r["cpu_pct"]),
             int(r["fd"])) for r in keep]


def at(s, t):
    """경과 t 초에 가장 가까운 샘플."""
    return min(s, key=lambda r: abs(r[0] - t)) if s else None


for tag, f in (("c 클라이언트", "sample_c.csv"), ("r 릴레이", "sample_r.csv"),
               ("s 서버", "sample_s.csv")):
    a, b = os.path.join(NEW, f), os.path.join(OLD, f)
    if not (os.path.exists(a) and os.path.exists(b)):
        print(f"{tag}: 자료 없음"); continue
    sa, sb = series(a), series(b)
    print(f"\n=== {tag} — v1.3.1 vs v1.3.0(09-02) ===")
    print(f"{'경과':>6} {'RSS 1.3.1':>10} {'RSS 1.3.0':>10} {'Δ MB':>8} "
          f"{'CPU 1.3.1':>10} {'CPU 1.3.0':>10} {'FD':>8}")
    for m in (5, 10, 15, 20, 25, 29):
        ra, rb = at(sa, m * 60), at(sb, m * 60)
        if not ra or not rb or ra[0] > (m * 60 + 90):
            continue
        print(f"{m:>4}분 {ra[1]:>10.2f} {rb[1]:>10.2f} {ra[1]-rb[1]:>+8.2f} "
              f"{ra[2]:>10.1f} {rb[2]:>10.1f} {str(ra[3])+'/'+str(rb[3]):>8}")
