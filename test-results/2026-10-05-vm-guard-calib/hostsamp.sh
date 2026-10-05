#!/bin/bash
# hostsamp.sh — 호스트 로컬 1초 샘플러 (VM 가드 재보정용, 2026-10-05)
#
# 왜 로컬인가: 가드처럼 ssh 로 매초 재면 피측정 호스트에 sshd 비용이 얹힌다(2026-09-05,
# Atom 에서 +10p). 여기서는 호스트 안에서 /proc 만 읽어 CSV 로 남기고 끝나면 회수한다.
#
# 사용: hostsamp.sh <out.csv> <iface[,iface]>      종료는 pidfile(<out>.pid) 로 kill
# 열:  t, tot, max, c0, c1, ..., sirq_max, steal_tot, mbps, mf_cpu
#   tot/max/cN = busy%(user+nice+system+irq+softirq+steal) — 가드 probe 와 같은 수식
#   mf_cpu     = multi-fec-dist 프로세스 합 CPU% (논리CPU 1개 = 100)
OUT=$1; IFS_=$2
echo $$ > "$OUT.pid"
HZ=$(getconf CLK_TCK)
read_cpu() { grep -E '^cpu[0-9]+ ' /proc/stat; }
read_net() { awk -v l="$IFS_" 'BEGIN{n=split(l,a,",");for(k=1;k<=n;k++)w[a[k]":"]=1} ($1 in w){s+=$2+$10} END{printf "%d", s}' /proc/net/dev; }
read_mf()  { local s=0; for p in $(pgrep -x multi-fec-dist); do
               s=$((s + $(awk '{print $14+$15}' /proc/$p/stat 2>/dev/null || echo 0))); done; echo $s; }
A=$(read_cpu); NA=$(read_net); MA=$(read_mf); TA=$(date +%s.%N)
NC=$(echo "$A" | wc -l)
{ printf "t,tot,max"; for i in $(seq 0 $((NC-1))); do printf ",c%d" $i; done; echo ",sirq_max,steal_tot,mbps,mf_cpu"; } > "$OUT"
while sleep 1; do
  B=$(read_cpu); NB=$(read_net); MB=$(read_mf); TB=$(date +%s.%N)
  printf '%s\n---\n%s\n' "$A" "$B" | awk -v ta=$TA -v tb=$TB -v na=$NA -v nb=$NB -v ma=$MA -v mb=$MB -v hz=$HZ '
    /^---$/ {s=1; next}
    { busy=$2+$3+$4+$7+$8+$9; tot=busy+$5+$6
      if (!s) {b0[$1]=busy; t0[$1]=tot; q0[$1]=$8; st0[$1]=$9; ord[++n]=$1}
      else    {b1[$1]=busy; t1[$1]=tot; q1[$1]=$8; st1[$1]=$9} }
    END { d=tb-ta; sb=0; st=0; mx=0; sq=0; ss=0; line=""
      for (i=1;i<=n;i++) { k=ord[i]; db=b1[k]-b0[k]; dt=t1[k]-t0[k]; if (dt<=0) dt=1
        p=db/dt*100; sb+=db; st+=dt; if (p>mx) mx=p; line=line sprintf(",%.1f",p)
        qq=(q1[k]-q0[k])/dt*100; if (qq>sq) sq=qq; ss+=st1[k]-st0[k] }
      printf "%.3f,%.1f,%.1f%s,%.1f,%.1f,%.2f,%.1f\n", tb, sb/st*100, mx, line, sq, ss/st*100,
             (nb-na)*8/d/1e6, (mb-ma)/hz/d*100 }' >> "$OUT"
  A=$B; NA=$NB; MA=$MB; TA=$TB
done
