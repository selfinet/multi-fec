#!/bin/bash
# verify.sh — 시험 후 상태를 시험 전 스냅샷(baseline/*.snap)과 대조
cd "$(dirname "$0")"
rc=0
for h in j86 j83; do
  ./snap.sh $h > baseline/$h.after
  if diff -u baseline/$h.snap baseline/$h.after > baseline/$h.diff; then echo "  ✓ $h 시험 전과 동일"
  else echo "  ✗ $h 차이:"; sed -n '3,40p' baseline/$h.diff; rc=1; fi
done
exit $rc
