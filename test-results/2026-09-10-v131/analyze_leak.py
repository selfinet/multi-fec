#!/usr/bin/env python3
"""analyze_leak.py — v1.3.1 누수 판정 (30분 다중 세션 소크)

판정 방법은 [[measurement-harness-pitfalls]] §18·§19 를 따른다:
  §18 RSS 는 계단 함수다 → **기울기 단독 금지.** 값이 바뀐 횟수와 마지막
      변화 이후 평탄 구간 길이로 판정한다(기울기는 참고로만 함께 낸다).
  §19 기동·종료 샘플이 섞이면 판정이 뒤집힌다 → `nproc` **모드값 행만** 남긴다.
"""
import csv, os, statistics as st, sys

D = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(D, sys.argv[1] if len(sys.argv) > 1 else "wg_raw")


def slope_per_h(pts):
    n = len(pts)
    if n < 3:
        return 0.0
    mt = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    num = sum((a - mt) * (b - my) for a, b in pts)
    den = sum((a - mt) ** 2 for a, _ in pts)
    return num / den * 3600 if den else 0.0


def report(tag, path):
    if not os.path.exists(path):
        print(f"  {tag}: 파일 없음 {path}")
        return
    rows = [r for r in csv.DictReader(open(path)) if r.get("t")]
    if not rows:
        print(f"  {tag}: 행 없음")
        return
    npr = [int(r["nproc"]) for r in rows]
    mode = st.mode(npr)
    keep = [r for r in rows if int(r["nproc"]) == mode]
    t0 = int(keep[0]["t"])
    rss = [(int(r["t"]) - t0, int(r["rss_kb"])) for r in keep]
    fd = [int(r["fd"]) for r in keep]
    cpu = [float(r["cpu_pct"]) for r in keep]
    sysb = [float(r["sys_busy_pct"]) for r in keep]
    dur = rss[-1][0]

    # 계단: 값이 바뀐 지점
    steps = [(t, v) for (pt, pv), (t, v) in zip(rss, rss[1:]) if v != pv]
    last_change = steps[-1][0] if steps else 0
    flat_tail = dur - last_change
    # 램프 이후 = 마지막 계단 이후 구간 + 참고로 후반 절반
    half = len(rss) // 2
    print(f"  {tag}: 프로세스 {mode}개 · 샘플 {len(keep)}/{len(rows)} · {dur/60:.1f}분")
    print(f"      RSS  {rss[0][1]/1024:.2f} → {rss[-1][1]/1024:.2f} MB "
          f"(Δ {(rss[-1][1]-rss[0][1])/1024:+.2f} MB, 프로세스당 {(rss[-1][1]-rss[0][1])/1024/mode:+.3f})")
    print(f"      계단  {len(steps)}회 · 마지막 변화 t={last_change}s → **평탄 {flat_tail/60:.1f}분**"
          f" · 최대 계단 {max((abs(v-pv) for (_, pv), (_, v) in zip(rss, rss[1:])), default=0)/1024:.2f} MB")
    print(f"      기울기(참고) 전구간 {slope_per_h(rss)/1024:+.3f} MB/h · "
          f"후반절반 {slope_per_h(rss[half:])/1024:+.3f} MB/h")
    print(f"      FD   {min(fd)}~{max(fd)} (마지막 {fd[-1]}) · "
          f"CPU 전반 {st.mean(cpu[:half]):.1f}% → 후반 {st.mean(cpu[half:]):.1f}% "
          f"({st.mean(cpu[half:])-st.mean(cpu[:half]):+.1f}p)")
    print(f"      호스트 busy 전반 {st.mean(sysb[:half]):.1f}% → 후반 {st.mean(sysb[half:]):.1f}% "
          f"(max {max(sysb):.1f}%)")


print(f"=== 누수 판정 · {RAW} ===")
for tag, f in (("c 클라이언트", "sample_c.csv"), ("r 릴레이", "sample_r.csv"),
               ("s 서버", "sample_s.csv"), ("부하생성기", "sample_blast.csv")):
    report(tag, os.path.join(RAW, f))

res = os.path.join(RAW, "result.csv")
if os.path.exists(res):
    print("\n=== 전달 (mf_blast) ===")
    txt = [l for l in open(res, errors="replace").read().splitlines() if l.strip()]
    print("\n".join(txt[:2] + (["..."] if len(txt) > 6 else []) + txt[-4:]))
