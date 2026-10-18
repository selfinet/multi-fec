#!/usr/bin/env python3
"""leak60_analyze.py — leak60.sh 의 프로세스 샘플(10초)로 누수를 판정한다 (2026-10-18)

  python3 leak60_analyze.py raw/leak60 ../2026-10-05-vm-guard-calib/raw/leak60/steps.txt

판정 (memory: 누수는 기울기가 아니라 계단 개수 · 마지막 평탄 구간):
  - RSS 를 부하 시작 기준 10분 단위로 찍고, 계단(직전 샘플보다 64 kB 이상 증가) 횟수와 시각을 센다.
  - 부하 마지막 30분의 RSS 변화량과 선형 기울기(kB/h). 램프가 끝났다면 0 근처여야 한다.
  - FD · 스레드는 최소/최대가 같아야 한다.
  - CPU(%) 는 부하 처음 10분과 마지막 10분을 비교한다 — 시간이 지나며 오르면 누적 비용이 있다는 뜻.
"""
import collections, sys

out, steps = sys.argv[1], sys.argv[2]
# steps.txt: 부하 구간 여러 줄 "10 t0 t1" — 판정 창은 첫 구간 시작 ~ 마지막 구간 끝 (구간 사이 휴지 포함)
seg = [l.split() for l in open(steps) if l.strip()]
L0, L1 = float(seg[0][1]), float(seg[-1][2])
HZ, STEP_KB = 100.0, 64

for host in ('c', 'r', 's'):
    rows = collections.defaultdict(list)
    for line in open(f'{out}/rss_{host}.log', errors='replace'):
        f = line.split()
        if len(f) < 6 or not f[0].isdigit() or not f[1].isdigit():
            continue
        t, pid, rss, th, fd, cpu = int(f[0]), f[1], int(f[2]), int(f[3]), int(f[4]), int(f[5])
        listen = f[6] if len(f) > 6 else '?'
        rows[(pid, listen)].append((t, rss, th, fd, cpu))
    for (pid, listen), v in rows.items():
        v.sort()
        load = [x for x in v if L0 <= x[0] <= L1]
        if len(load) < 10:
            print(f'{host} pid {pid} {listen}: 부하 구간 샘플 부족 ({len(load)})'); continue
        def at(m):  # RSS m분 시점(부하 시작 기준)
            c = [x for x in load if x[0] >= L0 + m * 60]
            return c[0][1] if c else load[-1][1]
        marks = ' '.join(f'{m:2d}m {at(m)/1024:6.2f}' for m in range(0, int((L1 - L0) / 60) + 1, 10))
        stepsup = [(x[0] - L0, x[1] - p[1]) for p, x in zip(load, load[1:]) if x[1] - p[1] >= STEP_KB]
        last = [x for x in load if x[0] >= L1 - 1800]
        n = len(last); mt = sum(x[0] for x in last) / n; mr = sum(x[1] for x in last) / n
        slope = sum((x[0] - mt) * (x[1] - mr) for x in last) / max(1e-9, sum((x[0] - mt) ** 2 for x in last)) * 3600
        def cpu_pct(seg):
            return (seg[-1][4] - seg[0][4]) / HZ / max(1, seg[-1][0] - seg[0][0]) * 100 if len(seg) > 1 else 0
        first10 = [x for x in load if x[0] <= L0 + 600]
        last10 = [x for x in load if x[0] >= L1 - 600]
        pre = [x for x in v if x[0] < L0]
        print(f'== {host} pid {pid} listen {listen}')
        print(f'   RSS MB (부하 시작 기준)  {marks}   | 유휴 {pre[-1][1]/1024 if pre else 0:.2f} · 최대 {max(x[1] for x in load)/1024:.2f}')
        print(f'   계단(≥{STEP_KB} kB) {len(stepsup)}회' + (': ' + ', '.join(f'{t/60:.0f}m +{d}kB' for t, d in stepsup[:12]) if stepsup else ''))
        print(f'   마지막 30분: 변화 {last[-1][1]-last[0][1]:+d} kB · 기울기 {slope:+.0f} kB/h · 범위 {min(x[1] for x in last)}~{max(x[1] for x in last)} kB')
        print(f'   FD {min(x[3] for x in v)}~{max(x[3] for x in v)} · 스레드 {min(x[2] for x in v)}~{max(x[2] for x in v)}'
              f' · CPU 처음 10분 {cpu_pct(first10):.1f}% → 마지막 10분 {cpu_pct(last10):.1f}%')
