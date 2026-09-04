#!/usr/bin/env python3
"""rt_multi.py 의 생성기 코어만 떼어낸 A/B 용 스크립트 (클라이언트 미기동).
루프 구조·sleep(0.0005)·캐치업 클램프를 그대로 옮겨 C 판과 같은 조건에서 비교한다."""
import socket, sys, threading, time
N=int(sys.argv[1]); MBPS=float(sys.argv[2]); SECS=float(sys.argv[3]); PORT=int(sys.argv[4]); SIZE=1200
socks=[]
for i in range(N):
    s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET,socket.SO_RCVBUF,4<<20); s.bind(("127.0.0.1",0)); s.settimeout(0.2)
    socks.append(s)
sent=[0]*N; own=[0]*N; foreign=[0]*N; bad=[0]*N; stop=threading.Event()
def drain(i):
    while not stop.is_set():
        try: d,_=socks[i].recvfrom(65535)
        except socket.timeout: continue
        except Exception: break
        if len(d)<11 or d[0:1]!=b"S": bad[i]+=1; continue
        try: sid=int(d[1:3])
        except ValueError: bad[i]+=1; continue
        if sid==i: own[i]+=1
        else: foreign[i]+=1
ths=[threading.Thread(target=drain,args=(i,),daemon=True) for i in range(N)]
for t in ths: t.start()
pps=MBPS*1e6/8/SIZE; gap=1.0/pps; filler=b"x"*max(0,SIZE-11)
end=time.time()+SECS; nxt=[time.time()]*N; seq=[0]*N; resets=0
while time.time()<end:
    now=time.time()
    for i in range(N):
        if now>=nxt[i]:
            socks[i].sendto(b"S%02d#%07d"%(i,seq[i]%10000000)+filler,("127.0.0.1",PORT))
            seq[i]+=1; sent[i]+=1; nxt[i]+=gap
            if nxt[i]<now-0.5: nxt[i]=now; resets+=1
    time.sleep(0.0005)
time.sleep(4); stop.set()
for t in ths: t.join(timeout=2)
ts=sum(sent); to=sum(own)
print(f"TOTAL,{ts},{to},{100*to/ts if ts else 0:.4f},{sum(foreign)},{sum(bad)}")
print(f"pacing_resets={resets} target_total_pps={pps*N:.1f} achieved_pps={ts/SECS:.1f}", file=sys.stderr)
