#!/usr/bin/env python3
"""analyze_soak.py — 18 Mbps 1시간 지속 소크 분석.

핵심 질문: **45초 계단이 준 수치가 1시간 지속에서도 유지되는가.**
그래서 "평균이 얼마인가" 보다 **시간에 따라 나빠지는가**를 본다 —
전반 30분 vs 후반 30분을 갈라서 비교한다.
"""
import csv, os, re, sys

D = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(D, sys.argv[1] if len(sys.argv) > 1 else "soak")
# 시험 경로에 속하는 인터페이스. `starlink-fec` 는 **부하가 실제로 흐르는 WG 터널**이다
# (규칙 1 — 트래픽은 10.9.10.2↔10.9.10.1 사이에서만). 외부 유출이 아니라 앱 계층 그 자체이고,
# 여기서 multi-fec 을 거쳐 enp2s0/ens18 로 나갈 때 FEC+duplicate 증폭이 붙는다.
TESTNET = {"c": {"enp2s0", "starlink-fec"},
           "r": {"ens18"},
           "s": {"ens18", "starlink-fec"}}
LAYER = {"starlink-fec": "앱 계층 (WG 터널)"}
# 계단(2026-08-06, 45초) 각 방향 18 Mbps 단계의 값 — 비교 기준
LADDER = {"tx_loss": 0.0, "rx_loss": 0.033, "c_cpu": 46.2, "c_core": 64.8, "ooo": 3806}


def slope(pts):
    n = len(pts)
    if n < 3:
        return 0.0
    mt = sum(p[0] for p in pts) / n
    my = sum(p[1] for p in pts) / n
    num = sum((p[0] - mt) * (p[1] - my) for p in pts)
    den = sum((p[0] - mt) ** 2 for p in pts)
    return (num / den * 3600) if den else 0.0


def iperf():
    p = os.path.join(RAW, "iperf.log")
    if not os.path.exists(p):
        print("  iperf.log 없음"); return
    txt = open(p, errors="replace").read()

    # 구간 줄: [ id][TX-C or RX-C]  a-b sec  X MBytes  Y Mbits/sec  jitter ms  lost/total (p%)
    iv = re.compile(r"\[\s*\d+\]\[(TX-C|RX-C)\]\s+([\d.]+)-([\d.]+)\s+sec\s+\S+\s+\S+\s+"
                    r"([\d.]+)\s+Mbits/sec(?:\s+([\d.]+)\s+ms\s+(\d+)/(\d+)\s+\(([\d.eE+-]+)%\))?")
    rx = []            # (t_mid, bitrate, loss%)
    for m in iv.finditer(txt):
        d, a, b, bw, jit, lost, tot, pct = m.groups()
        if d == "RX-C" and pct is not None:
            rx.append((float(a), float(bw), float(pct)))
    if rx:
        half = len(rx) // 2
        f, s = rx[:half], rx[half:]
        print(f"  s→c 구간 {len(rx)}개 (60초)")
        print(f"    실효   전반 {sum(x[1] for x in f)/len(f):.2f} → 후반 {sum(x[1] for x in s)/len(s):.2f} Mbps")
        print(f"    손실   전반 {sum(x[2] for x in f)/len(f):.4f}% → 후반 {sum(x[2] for x in s)/len(s):.4f}%"
              f"   (최대 {max(x[2] for x in rx):.4f}%)")
        sl = slope([(x[0], x[2]) for x in rx])
        print(f"    손실 기울기 {sl:+.5f} %p/시간  → {'악화 없음' if abs(sl) < 0.05 else '⚠️ 시간에 따라 변함'}")
        worst = sorted(rx, key=lambda x: -x[2])[:3]
        print("    최악 구간: " + ", ".join(f"{int(t)}s {p:.3f}%" for t, _, p in worst))

    # 최종 요약 (sender/receiver 줄)
    print()
    for line in txt.splitlines():
        if "receiver" in line and ("TX-C" in line or "RX-C" in line):
            print("   ", line.strip())
        elif "out-of-order" in line:
            print("   ", line.strip())


def cpu():
    p = os.path.join(RAW, "cpu_timeline.log")
    if not os.path.exists(p):
        print("  cpu_timeline.log 없음"); return
    cur, rows = None, []
    for line in open(p, errors="replace"):
        if line.startswith("---"):
            cur = line.strip()[4:]
        m = re.match(r"\s+([crs])\s+전체\s+([\d.]+)%/\d+%\s+최고1코어\s+([\d.]+)%", line)
        if m:
            rows.append((cur, m.group(1), float(m.group(2)), float(m.group(3))))
    if not rows:
        print("  파싱 실패"); return
    for h in "crs":
        v = [r for r in rows if r[1] == h]
        if not v:
            continue
        half = len(v) // 2
        f, s = v[:half], v[half:]
        lim = 62 if h == "c" else 75
        print(f"  {h}  샘플 {len(v)}개")
        print(f"     전체    전반 {sum(x[2] for x in f)/len(f):5.1f}% → 후반 {sum(x[2] for x in s)/len(s):5.1f}%"
              f"   최대 {max(x[2] for x in v):5.1f}% / 임계 {lim}%")
        print(f"     최고1코어 전반 {sum(x[3] for x in f)/len(f):5.1f}% → 후반 {sum(x[3] for x in s)/len(s):5.1f}%"
              f"   최대 {max(x[3] for x in v):5.1f}% / 임계 85%")


def leak():
    for tag, f in (("c 클라이언트", "sample_c.csv"), ("r 릴레이 2", "sample_r.csv"),
                   ("s 서버", "sample_s.csv")):
        p = os.path.join(RAW, f)
        if not os.path.exists(p):
            print(f"  {tag}: 없음"); continue
        rows = [r for r in csv.DictReader(open(p)) if r.get("rss_kb")]
        if len(rows) < 6:
            print(f"  {tag}: 샘플 부족 ({len(rows)})"); continue
        full = max(int(r["nproc"]) for r in rows)
        rows = [r for r in rows if int(r["nproc"]) == full]
        t = [int(r["t"]) for r in rows]
        rss = [int(r["rss_kb"]) / 1024.0 for r in rows]
        fd = [int(r["fd"]) for r in rows]
        cut = t[-1] - 1800
        last = [(a, b) for a, b in zip(t, rss) if a >= cut]
        lfd = [d for a, d in zip(t, fd) if a >= cut]
        s30 = slope(last)
        print(f"  {tag} (프로세스 {full})  RSS {rss[0]:.1f} → {rss[-1]:.1f} MB (최대 {max(rss):.1f})")
        print(f"     마지막 30분 기울기 {s30:+.2f} MB/시간 · FD {min(lfd)}~{max(lfd)}"
              f" {'고정 ✓' if min(lfd)==max(lfd) else '변동 ✗'}"
              f"  → {'누수 없음' if s30 < 1.0 else '⚠️ 확인 필요'}")


def containment():
    p = os.path.join(RAW, "ifsnap.txt")
    if not os.path.exists(p):
        print("  ifsnap.txt 없음"); return
    snap = {}
    for line in open(p):
        f = line.split()
        if len(f) == 6:
            snap[(f[0], f[1], f[2])] = (int(f[3]), int(f[4]), int(f[5]))
    ok = True
    for host, iface in sorted({(h, i) for (_, h, i) in snap}):
        g = lambda l: snap.get((l, host, iface))
        a, b, c, d = g("idle0"), g("idle1"), g("load0"), g("load1")
        if not all((a, b, c, d)):
            continue
        di = ((b[0]-a[0])+(b[1]-a[1]))*8/max(1, b[2]-a[2])/1e6
        dl = ((d[0]-c[0])+(d[1]-c[1]))*8/max(1, d[2]-c[2])/1e6
        rise = dl - di
        if iface in TESTNET.get(host, set()):
            tag = LAYER.get(iface, "테스트망 (전송 계층)")
        elif rise > 0.05:
            tag = f"⚠️ 외부에 +{rise:.3f} Mbps"; ok = False
        else:
            tag = "유휴 유지 ✓"
        print(f"  {host:<3}{iface:<15}{di:>9.3f}{dl:>10.3f}{rise:>+10.3f}   {tag}")
    print("\n  격납: " + ("✓ 테스트망 밖으로 나간 트래픽 없음" if ok else "✗ 외부 인터페이스 증가"))


for title, fn in (("① 앱 실효·손실 (시간에 따라 나빠지는가)", iperf),
                  ("② CPU (전반 vs 후반)", cpu),
                  ("③ 메모리·FD 누수", leak),
                  ("④ 트래픽 격납", containment)):
    print("=" * 78); print(title); print("=" * 78)
    fn(); print()

print("=" * 78)
print("⑤ 45초 계단(2026-08-06, 각 방향 18) 대비")
print("=" * 78)
print(f"  계단 기준: c→s 손실 {LADDER['tx_loss']}% · s→c {LADDER['rx_loss']}% · "
      f"c 전체 {LADDER['c_cpu']}% · 최고1코어 {LADDER['c_core']}% · OoO {LADDER['ooo']:,}")
print("  → 위 ①②와 대조해 지속 부하에서 유지되는지 판단한다 (OoO 는 시간에 비례하므로 45초분으로 환산할 것)")
