#!/bin/bash
# run_d.sh <label> <bin> <N> <args...> — duplicate 계측 로그(DUPDBG·client 경고)를 회차별로 남긴다
cd /root/aggtest; L=$1; B=$2; N=$3; shift 3
for i in $(seq 1 $N); do
  r=$(BIN=$B python3 ./test_path_failure.py --single "$@" 2>&1 | grep -E "고유전달")
  echo "$L run$i $* | $r" | tee -a out/results.txt
  grep -aE "DUPDBG|\[client\]" /tmp/mf_cli.log > out/dupdbg_${L}_run$i.txt 2>/dev/null
done
echo DUP2_DONE >> out/results.txt
