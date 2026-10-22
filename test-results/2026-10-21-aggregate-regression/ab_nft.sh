#!/bin/bash
# ab_nft.sh — mf-nftstat 꺼짐/켜짐을 번갈아 duplicate 10초 절단 시험 (1.4.0). 끝나면 반드시 켠다.
cd /root/aggtest
trap 'systemctl start mf-nftstat; echo "nft 복구: $(systemctl is-active mf-nftstat) $(nft list tables | tr "\n" " ")" >> out/ab_nft.txt; echo AB_DONE >> out/results.txt' EXIT
for i in $(seq 1 10); do
  for st in off on; do
    if [ $st = off ]; then systemctl stop mf-nftstat; else systemctl start mf-nftstat; fi
    sar_before=$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' /proc/stat)
    r=$(BIN=./mf140 python3 ./test_path_failure.py --single duplicate 0 0 10 5000 200000 2>&1 | grep -E "고유전달")
    sar_after=$(awk '/^cpu /{print $2+$3+$4+$6+$7+$8, $5}' /proc/stat)
    cpu=$(echo "$sar_before $sar_after" | awk '{b=$3-$1; i=$4-$2; printf "%.0f", 100*b/(b+i)}')
    echo "nft-$st pair$i cpu=${cpu}% $(nft list tables 2>/dev/null | grep -c mfstat)tbl | $r" | tee -a out/ab_nft.txt
  done
done
