#!/bin/bash
# run.sh <label> <bin> <N> <mode> <bloss> <skew> <killat> [rate] [count] — test_path_failure.py --single 을 N 회. 결과·계측 로그를 out/ 에 남긴다.
cd /root/aggtest; L=$1; B=$2; N=$3; shift 3
mkdir -p out
for i in $(seq 1 $N); do
  r=$(BIN=$B python3 ./test_path_failure.py --single "$@" 2>&1 | grep -E "고유전달")
  echo "$L run$i $* | $r" | tee -a out/results.txt
  grep -a AGGDBG /tmp/mf_cli.log > out/aggdbg_${L}_$(echo "$*" | tr ' ' '_')_run$i.txt 2>/dev/null
done
