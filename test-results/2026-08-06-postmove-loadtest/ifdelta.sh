#!/bin/bash
DUR=${1:-10}
snap() {  # $1=host  $2=label
  ssh -o ConnectTimeout=5 "$1" "
    A=\$(grep ':' /proc/net/dev); T0=\$(date +%s.%N)
    sleep $DUR
    B=\$(grep ':' /proc/net/dev); T1=\$(date +%s.%N)
    printf '%s\n===\n%s\n' \"\$A\" \"\$B\" | awk -v t0=\$T0 -v t1=\$T1 -v lb='$2' '
      /^===\$/ { s=1; next }
      { gsub(/:/,\"\",\$1); if (\$1==\"lo\") next
        if (!s) { r0[\$1]=\$2; x0[\$1]=\$10 } else { r1[\$1]=\$2; x1[\$1]=\$10 } }
      END { d=t1-t0; if (d<=0) d=$DUR
        for (k in r1) {
          rx=(r1[k]-r0[k])*8/d/1e6; tx=(x1[k]-x0[k])*8/d/1e6
          if (rx>0.01 || tx>0.01) printf \"    %-2s %-13s RX %8.3f  TX %8.3f Mbps\n\", lb, k, rx, tx
        } }'" 2>/dev/null
}
snap c.xdn.selfinet.com c & snap r.xdn.selfinet.com r & snap s.xdn.selfinet.com s &
wait
