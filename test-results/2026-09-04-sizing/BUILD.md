# mf_blast 빌드

정적 바이너리는 커밋하지 않는다(1.8 MB, 공개 리포). 한 줄로 만든다:

```bash
gcc -O2 -Wall -Wextra -static -o mf_blast mf_blast.c    # 경고 0 이어야 한다
```

sv1(Ubuntu 24.04, gcc 13.3.0)에서 빌드해 c 로 배포한다 — `mf_wg_multi.sh` /
`mf_amp_ladder.sh` 의 "2. 배포" 단계가 `scp` 하고 실행 가능 여부까지 확인한다.

## 자체 검증

```bash
./rt_echo_ip.py 127.0.0.1 44999 &          # 또는 rt_echo.py 44999
./mf_blast --no-clients --echo-port 44999 --sessions 4 --mbps 4 --secs 20
# pacing_resets=0 · sendfail=0 · own_pct ~100% 이어야 한다
```

`pacing_resets` 가 0 이 아니면 생성기가 목표 레이트를 못 낸 것이므로 그 런의
결과를 믿으면 안 된다.
