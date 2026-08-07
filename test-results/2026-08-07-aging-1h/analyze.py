#!/usr/bin/env python3
"""analyze.py — 1시간 에이징 결과 분석: ① 누수 ② 트래픽 격납 ③ 전달

누수 판정은 **후반 기울기**로 한다. 전반은 페이지를 처음 만지며 오르는 램프라
기울기가 양수인 것이 정상이고, 그것과 누수를 구분하는 것이 요점이다
(2026-08-03 8세션 1시간: 전반 +22~25 MB/h → 후반 정확히 0).
"""
import csv, os, sys

D = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(D, "raw")

# 테스트망 인터페이스 — 여기만 부하를 실어야 한다
TESTNET = {"c": {"enp2s0"}, "r": {"ens18"}, "s": {"ens18"}}


def slope(pts):
    """(t, y) 리스트 → 최소제곱 기울기 (y 단위/시간)"""
    n = len(pts)
    if n < 3:
        return 0.0
    mt = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    num = sum((p[0] - mt) * (p[1] - my) for p in pts)
    den = sum((p[0] - mt) ** 2 for p in pts)
    return (num / den * 3600) if den else 0.0


def leak(tag, path):
    if not os.path.exists(path):
        print(f"  {tag}: 파일 없음"); return
    allrows = [r for r in csv.DictReader(open(path)) if r.get("rss_kb")]
    if len(allrows) < 6:
        print(f"  {tag}: 샘플 부족 ({len(allrows)})"); return

    # 프로세스가 전부 뜬 구간만 본다. 기동 중 행(nproc 미달)을 섞으면 RSS 계열이
    # "아직 안 뜬 프로세스" 와 "뜬 프로세스" 의 합을 오가서 램프 기울기가 왜곡된다.
    full = max(int(r["nproc"]) for r in allrows)
    rows = [r for r in allrows if int(r["nproc"]) == full]
    skipped = len(allrows) - len(rows)

    t = [int(r["t"]) for r in rows]
    rss = [int(r["rss_kb"]) / 1024.0 for r in rows]
    fd = [int(r["fd"]) for r in rows]
    cpu = [float(r["cpu_pct"]) for r in rows]
    half = len(rows) // 2
    s_all = slope(list(zip(t, rss)))
    s_1st = slope(list(zip(t[:half], rss[:half])))
    s_2nd = slope(list(zip(t[half:], rss[half:])))
    # 마지막 30분 — 2026-08-03 검증이 쓴 것과 같은 기준
    cut = t[-1] - 1800
    last = [(a, b) for a, b in zip(t, rss) if a >= cut]
    s_30 = slope(last)
    dur = (t[-1] - t[0]) / 60.0
    print(f"  {tag}  프로세스 {full}개 · 샘플 {len(rows)}개 · {dur:.0f}분"
          + (f"  (기동 중 {skipped}행 제외)" if skipped else ""))
    print(f"    RSS   {rss[0]:.1f} → {rss[-1]:.1f} MB   (최대 {max(rss):.1f})")
    print(f"    기울기 전체 {s_all:+.2f} · 전반 {s_1st:+.2f} · 후반 {s_2nd:+.2f}"
          f" · **마지막 30분 {s_30:+.2f} MB/시간** ({len(last)}샘플)")
    print(f"    FD    {min(fd)}~{max(fd)} {'(고정)' if min(fd)==max(fd) else '← 변동'}")
    print(f"    CPU   평균 {sum(cpu)/len(cpu):.1f}%  최대 {max(cpu):.1f}%  (논리1개=100%)")
    v = "누수 없음" if s_30 < 1.0 else ("의심" if s_30 < 5 else "**누수**")
    print(f"    판정  {v}  (마지막 30분 기울기 기준 — 전반은 페이지 최초 접촉 램프)")


def containment():
    p = os.path.join(RAW, "ifsnap.txt")
    if not os.path.exists(p):
        print("  ifsnap.txt 없음"); return
    snap = {}
    for line in open(p):
        f = line.split()
        if len(f) != 6:
            continue
        lab, host, iface, rx, tx, ts = f
        snap[(lab, host, iface)] = (int(rx), int(tx), int(ts))

    keys = sorted({(h, i) for (_, h, i) in snap})
    print(f"  {'호스트':<4} {'인터페이스':<14} {'유휴 Mbps':>10} {'부하 Mbps':>10} {'증가':>10}   판정")
    verdict_ok = True
    for host, iface in keys:
        a = snap.get(("idle0", host, iface)); b = snap.get(("idle1", host, iface))
        c = snap.get(("load0", host, iface)); d = snap.get(("load1", host, iface))
        if not (a and b and c and d):
            continue
        di = ((b[0] - a[0]) + (b[1] - a[1])) * 8 / max(1, b[2] - a[2]) / 1e6
        dl = ((d[0] - c[0]) + (d[1] - c[1])) * 8 / max(1, d[2] - c[2]) / 1e6
        rise = dl - di
        is_test = iface in TESTNET.get(host, set())
        if is_test:
            tag = "테스트망 (여기로 흘러야 함)"
        elif rise > 0.05:
            tag = f"⚠️ 외부 인터페이스에 +{rise:.3f} Mbps"; verdict_ok = False
        else:
            tag = "유휴 유지 ✓"
        print(f"  {host:<4} {iface:<14} {di:>10.3f} {dl:>10.3f} {rise:>+10.3f}   {tag}")
    print()
    print("  격납 판정: " + ("✓ 테스트망 밖으로 나간 트래픽 없음" if verdict_ok
                              else "✗ 테스트망 밖 인터페이스에서 증가 관측"))


def delivery():
    p = os.path.join(RAW, "result.csv")
    if not os.path.exists(p):
        print("  result.csv 없음"); return
    rows = [r for r in csv.DictReader(open(p)) if r.get("sent")]
    if not rows:
        print("  데이터 없음"); return
    ts = sum(int(r["sent"]) for r in rows)
    to = sum(int(r["own_back"]) for r in rows)
    tf = sum(int(r["foreign"]) for r in rows)
    tb = sum(int(r["bad"]) for r in rows)
    print(f"  {'세션':<6}{'송신':>9}{'자기태그회수':>13}{'회수율':>9}{'오배송':>8}{'불량':>7}")
    for r in rows:
        print(f"  {r['session']:<6}{int(r['sent']):>9,}{int(r['own_back']):>13,}"
              f"{float(r['own_pct']):>8.3f}%{int(r['foreign']):>8}{int(r['bad']):>7}")
    print(f"  {'합계':<6}{ts:>9,}{to:>13,}{to*100.0/ts:>8.3f}%{tf:>8}{tb:>7}")
    print()
    print(f"  왕복 {ts:,}회 · 손실 {ts-to:,} ({(ts-to)*100.0/ts:.5f}%) · "
          f"오배송 {tf} · 불량 {tb}")


print("=" * 78)
print("① CPU · 메모리 누수")
print("=" * 78)
for tag, f in (("c (클라 8 + 운영 1)", "sample_c.csv"),
               ("r (릴레이 2 + 운영 2)", "sample_r.csv"),
               ("s (서버 1, 8연결)", "sample_s.csv")):
    leak(tag, os.path.join(RAW, f)); print()

print("=" * 78)
print("② 트래픽 격납 — 테스트망(192.168.100.0/24) 밖으로 나갔는가")
print("=" * 78)
containment()

print()
print("=" * 78)
print("③ 전달 · 오배송")
print("=" * 78)
delivery()
