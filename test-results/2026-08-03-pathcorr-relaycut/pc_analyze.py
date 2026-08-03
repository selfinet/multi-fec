#!/usr/bin/env python3
"""pc_analyze.py — 경로 상관도 분할표 분석.

핵심 질문: duplicate 의 종단 손실을 `p1 × p2` 로 예측해도 되는가?
그건 두 경로의 손실이 **독립**일 때만 성립한다. 공유 구간(릴레이 호스트·gw)
에서 나는 손실은 두 사본을 동시에 죽이므로 완전 상관이고, 그만큼 예측이
낙관적이 된다.

입력: pc_sink.py 가 뱉은 JSON
"""
import json, math, sys

d = json.load(open(sys.argv[1]) if len(sys.argv) > 1 else sys.stdin)

n11, n10, n01, n00 = d["n11"], d["n10"], d["n01"], d["n00"]
N = n11 + n10 + n01 + n00

pa = (n01 + n00) / N          # A 손실 확률 (B 도착 여부 무관)
pb = (n10 + n00) / N          # B 손실 확률
pboth = n00 / N               # 실측 양쪽 동시 손실
pind = pa * pb                # 독립 가정 기대값

# φ (Matthews) 계수 — 손실 사건 기준
a_, b_, c_, d_ = n00, n01, n10, n11     # a=둘다손실, d=둘다도착
den = math.sqrt((a_ + b_) * (a_ + c_) * (d_ + b_) * (d_ + c_))
phi = ((a_ * d_ - b_ * c_) / den) if den else float("nan")

# 공유 구간 손실 추정: p_both = p_shared + (1-p_shared)·pa'·pb'
# 근사적으로 p_shared ≈ max(0, p_both - pa·pb)
p_shared = max(0.0, pboth - pind)

# 이항 95% 신뢰구간 (Wilson)
def wilson(k, n, z=1.96):
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    dnm = 1 + z * z / n
    c = (p + z * z / (2 * n)) / dnm
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / dnm
    return (max(0, c - h), c + h)


lo, hi = wilson(n00, N)

print("=" * 62)
print("경로 상관도 — 2x2 분할표  (pair N = %d)" % N)
print("=" * 62)
print()
print("                 B 도착      B 손실")
print("  A 도착      %9d   %9d" % (n11, n10))
print("  A 손실      %9d   %9d   <- n00 = 양쪽 동시 손실" % (n01, n00))
print()
print("  P(A 손실)            = %.4f%%" % (100 * pa))
print("  P(B 손실)            = %.4f%%" % (100 * pb))
print("  P(양쪽 손실) 실측    = %.5f%%   (%d 건, 95%%CI %.5f~%.5f%%)"
      % (100 * pboth, n00, 100 * lo, 100 * hi))
print("  P(양쪽 손실) 독립가정 = %.5f%%   (%.1f 건 기대)" % (100 * pind, pind * N))
print()
ratio = (pboth / pind) if pind else float("inf")
print("  실측 / 독립기대       = %.2f 배" % ratio)
print("  φ 상관계수            = %+.5f" % phi)
print("  공유구간 손실 추정    = %.5f%%" % (100 * p_shared))
print()
if lo <= pind <= hi:
    verdict = "독립과 구분되지 않음 — p1×p2 예측이 유효"
elif pboth > hi if False else pboth > pind:
    verdict = "독립보다 높음 — 양의 상관(공유 장애요소 존재)"
else:
    verdict = "독립보다 낮음 — 음의 상관(이례적, 재확인 필요)"
print("  판정: %s" % verdict)
print()
print("  [참고] 관측 부수효과")
print("    총 수신 패킷 %d, 중복 A=%d B=%d, 형식오류 %d"
      % (d["total_pkts"], d["dup_a"], d["dup_b"], d["bad"]))
