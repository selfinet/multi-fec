#!/bin/bash
# 10세션 아징: mode1 90분 + mode2 90분 (총 3시간)
cd ~/multi-fec
TS=$(date +%Y%m%d_%H%M%S)
DUR=5400        # 90분
RATE=50         # pkt/s/session
SESS=10
LOG1=aging10_mode1_${TS}.log
LOG2=aging10_mode2_${TS}.log
{
  echo "### START $(date) ###"
  echo "=== [1/2] mode1 RS 90min ==="
  python3 test_scale_sessions.py --mode 1 --fec 20:5 --sessions $SESS \
      --aging $DUR --sample 60 --rate $RATE 2>&1 | grep -v setlocale | tee $LOG1
  echo "=== [2/2] mode2 RNLC 90min ==="
  python3 test_scale_sessions.py --mode 2 --fec 20:5 --sessions $SESS \
      --aging $DUR --sample 60 --rate $RATE 2>&1 | grep -v setlocale | tee $LOG2
  echo "### DONE $(date) ###"
} > aging10_driver_${TS}.log 2>&1
echo "$TS" > ~/multi-fec/.aging10_ts
