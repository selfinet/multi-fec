#!/usr/bin/env python3
"""multi-fec 전체 옵션 시뮬레이션 테스트"""

import subprocess, socket, time, struct, threading, os, sys, select

BINARY = os.path.join(os.path.dirname(__file__), 'multi-fec')
PASS = 0; FAIL = 0; results = []

# ─── 헬퍼 ────────────────────────────────────────────────────────────────────

def check(name, cond, detail=''):
    global PASS, FAIL
    mark = '✓' if cond else '✗'
    if cond: PASS += 1
    else:    FAIL += 1
    results.append(('PASS' if cond else 'FAIL', name, detail))
    suffix = f'  [{detail}]' if detail else ''
    print(f'  {mark} {name}{suffix}', flush=True)

def quick_run(args, timeout=2.0):
    """짧게 실행하고 (rc, output) 반환. 이벤트 루프 진입 전 종료 기대."""
    try:
        r = subprocess.run([BINARY]+args, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout+r.stderr
    except subprocess.TimeoutExpired as e:
        # timeout = 이벤트 루프까지 진입한 것 (시작 성공)
        out = (e.stdout or b'').decode(errors='replace') + (e.stderr or b'').decode(errors='replace')
        return None, out  # None = timeout (still running)

def launch(args, wait=0.4):
    """백그라운드 프로세스 시작, wait 후 생존 여부 반환."""
    p = subprocess.Popen([BINARY]+args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(wait)
    alive = p.poll() is None
    if alive: p.terminate(); p.wait(timeout=2)
    else: p.wait()
    return alive

def udp_exchange(dst_port, data, src_bind=None, timeout=1.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if src_bind: s.bind(('127.0.0.1', src_bind))
    else:        s.bind(('127.0.0.1', 0))
    s.settimeout(timeout)
    s.sendto(data, ('127.0.0.1', dst_port))
    try: resp, _ = s.recvfrom(4096)
    except socket.timeout: resp = None
    s.close()
    return resp

class UDPListener:
    def __init__(self, port):
        self.pkts = []; self._stop = threading.Event()
        self._s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._s.bind(('127.0.0.1', port)); self._s.settimeout(0.2)
        self._t = threading.Thread(target=self._run, daemon=True)
    def start(self): self._t.start()
    def _run(self):
        while not self._stop.is_set():
            try: d,_ = self._s.recvfrom(4096); self.pkts.append(d)
            except: pass
    def stop(self): self._stop.set(); self._t.join(1); self._s.close()

# ─── obfs helpers ─────────────────────────────────────────────────────────────

M64=0xFFFFFFFFFFFFFFFF
DERIV_KEY=bytes([0x6d,0x75,0x6c,0x74,0x69,0x2d,0x66,0x65,0x63,0x2d,0x70,0x73,0x6b,0x2d,0x76,0x31])
def rotl64(v,n): return((v<<n)|(v>>(64-n)))&M64
def sipround(v0,v1,v2,v3):
    v0=(v0+v1)&M64;v1=rotl64(v1,13);v1^=v0;v0=rotl64(v0,32)
    v2=(v2+v3)&M64;v3=rotl64(v3,16);v3^=v2
    v0=(v0+v3)&M64;v3=rotl64(v3,21);v3^=v0
    v2=(v2+v1)&M64;v1=rotl64(v1,17);v1^=v2;v2=rotl64(v2,32)
    return v0,v1,v2,v3
def siphash24(data,key):
    k0,k1=struct.unpack_from('<QQ',key)
    v0=(k0^0x736f6d6570736575)&M64;v1=(k1^0x646f72616e646f6d)&M64
    v2=(k0^0x6c7967656e657261)&M64;v3=(k1^0x7465646279746573)&M64
    n=len(data);blocks=n//8
    for i in range(blocks):
        m=struct.unpack_from('<Q',data,i*8)[0]; v3^=m
        v0,v1,v2,v3=sipround(v0,v1,v2,v3);v0,v1,v2,v3=sipround(v0,v1,v2,v3);v0^=m
    b=(n&M64)<<56
    for i,byte in enumerate(data[blocks*8:]): b|=(byte<<(i*8))
    b&=M64;v3^=b;v0,v1,v2,v3=sipround(v0,v1,v2,v3);v0,v1,v2,v3=sipround(v0,v1,v2,v3);v0^=b
    v2^=0xff
    for _ in range(4): v0,v1,v2,v3=sipround(v0,v1,v2,v3)
    return(v0^v1^v2^v3)&M64
def derive_psk(k):
    kb=k.encode();h0=siphash24(kb,DERIV_KEY);h1=siphash24(kb+b'\x01',DERIV_KEY)
    return struct.pack('<QQ',h0,h1)
def make_obfs_quic(key,payload=b'test'):
    psk=derive_psk(key);slot=int(time.time())//30
    h=siphash24(struct.pack('<Q',slot),psk);token=struct.pack('<Q',h)
    raw=10+len(payload);buckets=[300,500,700,900,1100,1300,1400,1500]
    bucket=next((b for b in buckets if b>=raw),raw)
    pad=min(bucket-raw,245);pad=max(pad,0)
    pkt=bytearray(10+len(payload)+pad)
    pkt[0]=0x40|(token[0]&0x3F);pkt[1:8]=token[1:8];pkt[8]=token[0];pkt[9]=pad
    pkt[10:10+len(payload)]=payload;return bytes(pkt)

TLS_CLOSE_NOTIFY=bytes([0x15,0x03,0x03,0x00,0x02,0x01,0x00])
def is_quic_initial(d):
    return(d and len(d)>=1200 and d[0]==0xC1 and d[1:5]==b'\x00\x00\x00\x01' and d[15]==0xFF)

# 포트 충돌 방지: 테스트 시작 전 기존 프로세스 정리
subprocess.run(['pkill','-f','multi-fec'], capture_output=True)
time.sleep(0.5)

# ═══════════════════════════════════════════════════════════════════════════════
print('\n[1] CLI 유효성 검사')
# ═══════════════════════════════════════════════════════════════════════════════

rc,out = quick_run(['-l','127.0.0.1:9000','--disable-obfs'])
check('모드 없음 → 오류', rc not in (0, None))

rc,out = quick_run(['-c','--unknown-option'])
check('알 수 없는 옵션 → 오류', rc not in (0, None))

rc,out = quick_run(['--version'])
check('--version 정상', rc == 0 and 'multi-fec' in out.lower())

rc,out = quick_run(['-h'])
check('-h 정상', rc == 0 and '--multipath-mode' in out)

# ═══════════════════════════════════════════════════════════════════════════════
print('\n[2] 필수 옵션 누락 검사')
# ═══════════════════════════════════════════════════════════════════════════════

rc,out = quick_run(['-c','-l','127.0.0.1:9000','--disable-fec','--disable-obfs'])
check('클라이언트 --path 없음 → 오류', rc not in (0, None))

rc,out = quick_run(['-s','-l','127.0.0.1:9000','--disable-fec','--disable-obfs'])
check('서버 --wg 없음 → 오류', rc not in (0, None))

rc,out = quick_run(['-r','-l','127.0.0.1:9000'])
check('릴레이 --upstream/--route 없음 → 오류', rc not in (0, None))

# ═══════════════════════════════════════════════════════════════════════════════
print('\n[3] 옵션 범위 검사 (유효하지 않은 값 → 오류)')
# ═══════════════════════════════════════════════════════════════════════════════

invalid_cases = [
    ('--dup-factor 0',       ['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--dup-factor','0']),
    ('--dup-factor 9',       ['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--dup-factor','9']),
    ('--auth-interval 10',   ['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--auth-interval','10']),
    ('--port-hop-interval 5',['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--port-hop-interval','5']),
    ('--mtu 50',             ['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--mtu','50']),
    ('--mtu 1600',           ['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--mtu','1600']),
    ('--decode-buf 100',     ['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--decode-buf','100']),
    ('--sock-buf 5',         ['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--sock-buf','5']),
    ('--random-drop 20000',  ['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--random-drop','20000']),
    ('--multipath-mode bad', ['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--multipath-mode','bad']),
    ('--obfs-mode bad',      ['-c','-l','127.0.0.1:9','-k','k','--path','0.0.0.0:1.1.1.1:443','--obfs-mode','bad']),
    ('--route 형식오류',      ['-r','-l','127.0.0.1:9','--route','invalid']),
    ('--route 주소오류',      ['-r','-l','127.0.0.1:9','--route','key badaddr']),
]
for name, args in invalid_cases:
    rc,out = quick_run(args)
    check(f'{name} → 오류', rc not in (0, None))

# ═══════════════════════════════════════════════════════════════════════════════
print('\n[4] 유효 옵션 파싱 (이벤트 루프 진입 = 시작 성공)')
# ═══════════════════════════════════════════════════════════════════════════════

# 릴레이 모드 옵션들
relay_cases = [
    ('단일 upstream + -k',     ['-r','-l','127.0.0.1:29100','--upstream','127.0.0.1:9999','-k','key']),
    ('키별 라우팅 (--route)',   ['-r','-l','127.0.0.1:29101','--route','keyA 127.0.0.1:9001','--route','keyB 127.0.0.1:9002']),
    ('--decoy',                ['-r','-l','127.0.0.1:29102','--upstream','127.0.0.1:9999','-k','key','--decoy','127.0.0.1:8443']),
    ('--disable-obfs',         ['-r','-l','127.0.0.1:29103','--upstream','127.0.0.1:9999','--disable-obfs']),
    ('--obfs-mode quic',       ['-r','-l','127.0.0.1:29104','--upstream','127.0.0.1:9999','-k','key','--obfs-mode','quic']),
    ('--obfs-mode tls',        ['-r','-l','127.0.0.1:29105','--upstream','127.0.0.1:9999','-k','key','--obfs-mode','tls']),
    ('--auth-interval 60',     ['-r','-l','127.0.0.1:29106','--upstream','127.0.0.1:9999','-k','key','--auth-interval','60']),
    ('--log-level 0',          ['-r','-l','127.0.0.1:29107','--upstream','127.0.0.1:9999','--disable-obfs','--log-level','0']),
    ('--log-level 6',          ['-r','-l','127.0.0.1:29108','--upstream','127.0.0.1:9999','--disable-obfs','--log-level','6']),
    ('--sock-buf 4096',        ['-r','-l','127.0.0.1:29109','--upstream','127.0.0.1:9999','--disable-obfs','--sock-buf','4096']),
]
for name, args in relay_cases:
    alive = launch(args, wait=0.5)
    check(f'릴레이 {name}', alive)
    time.sleep(0.1)

# 클라이언트 모드 옵션들
client_base = ['-c','-l','127.0.0.1:29200','--path','0.0.0.0:127.0.0.1:9100','-k','key']

client_cases = [
    ('--multipath-mode failover',            ['--multipath-mode','failover','--disable-fec']),
    ('--multipath-mode duplicate',           ['--multipath-mode','duplicate','--disable-fec']),
    ('--multipath-mode aggregate',           ['--multipath-mode','aggregate','--disable-fec']),
    ('--multipath-mode aggregate-duplicate', ['--multipath-mode','aggregate-duplicate','--disable-fec']),
    ('--dup-factor 1',                       ['--multipath-mode','aggregate-duplicate','--dup-factor','1','--disable-fec']),
    ('--dup-factor 2',                       ['--multipath-mode','aggregate-duplicate','--dup-factor','2','--disable-fec']),
    ('--dup-factor 8',                       ['--multipath-mode','aggregate-duplicate','--dup-factor','8','--disable-fec']),
    ('--auth-interval 30',                   ['--auth-interval','30','--disable-fec']),
    ('--auth-interval 60',                   ['--auth-interval','60','--disable-fec']),
    ('--auth-interval 120',                  ['--auth-interval','120','--disable-fec']),
    ('--port-hop-interval 30',               ['--port-hop-interval','30','--disable-fec']),
    ('--port-hop-interval 60',               ['--port-hop-interval','60','--disable-fec']),
    ('-f 1:0',                               ['-f','1:0']),
    ('-f 10:3',                              ['-f','10:3']),
    ('-f 20:10',                             ['-f','20:10']),
    ('-f 5:5',                               ['-f','5:5']),
    ('--fec-timeout 0',                      ['--fec-timeout','0']),
    ('--fec-timeout 100',                    ['--fec-timeout','100']),
    ('--mode 0',                             ['--mode','0']),
    ('--mode 1',                             ['--mode','1']),
    ('--mtu 100',                            ['--mtu','100']),
    ('--mtu 1250',                           ['--mtu','1250']),
    ('--mtu 1500',                           ['--mtu','1500']),
    ('--queue-len 1',                        ['--queue-len','1']),
    ('--queue-len 10000',                    ['--queue-len','10000']),
    ('--decode-buf 300',                     ['--decode-buf','300']),
    ('--decode-buf 20000',                   ['--decode-buf','20000']),
    ('--disable-fec',                        ['--disable-fec']),
    ('--obfs-mode quic',                     ['--obfs-mode','quic','--disable-fec']),
    ('--obfs-mode tls',                      ['--obfs-mode','tls','--disable-fec']),
    ('--disable-obfs',                       ['--disable-obfs','--disable-fec']),
    ('--sock-buf 10',                        ['--sock-buf','10','--disable-fec']),
    ('--sock-buf 4096',                      ['--sock-buf','4096','--disable-fec']),
    ('--random-drop 0',                      ['--random-drop','0','--disable-fec']),
    ('--random-drop 1000',                   ['--random-drop','1000','--disable-fec']),
    ('--jitter 0',                           ['--jitter','0','--disable-fec']),
    ('--jitter 100',                         ['--jitter','100','--disable-fec']),
    ('--jitter 10:50',                       ['--jitter','10:50','--disable-fec']),
    ('--disable-checksum',                   ['--disable-checksum','--disable-fec']),
    ('--report 5',                           ['--report','5','--disable-fec']),
    ('--log-level 0',                        ['--log-level','0','--disable-fec']),
    ('--log-level 6',                        ['--log-level','6','--disable-fec']),
    ('--disable-color',                      ['--disable-color','--disable-fec']),
    ('--enable-color',                       ['--enable-color','--disable-fec']),
]
for name, extra in client_cases:
    alive = launch(client_base + extra, wait=0.4)
    check(f'클라이언트 {name}', alive)
    time.sleep(0.05)

# ═══════════════════════════════════════════════════════════════════════════════
print('\n[5] 릴레이 패킷 전달 기능')
# ═══════════════════════════════════════════════════════════════════════════════

# TC1: 투명 포워딩
up1 = UDPListener(29300); up1.start()
p1 = subprocess.Popen([BINARY,'-r','-l','127.0.0.1:29301',
                        '--upstream','127.0.0.1:29300','--disable-obfs'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.3)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(b'hello-transparent', ('127.0.0.1',29301)); s.close()
time.sleep(0.3)
p1.terminate(); p1.wait(2); up1.stop()
check('릴레이 투명 포워딩', len(up1.pkts)>0)

# TC2: HMAC 검증 후 정상 패킷 전달
up2 = UDPListener(29310); up2.start()
p2 = subprocess.Popen([BINARY,'-r','-l','127.0.0.1:29311',
                        '--upstream','127.0.0.1:29310','-k','mykey'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.3)
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.sendto(make_obfs_quic('mykey',b'ok'), ('127.0.0.1',29311)); s.close()
time.sleep(0.3)
p2.terminate(); p2.wait(2); up2.stop()
check('릴레이 올바른 키 패킷 upstream 전달', len(up2.pkts)>0)

# TC3: 잘못된 키 → upstream 미전달
up3 = UDPListener(29320); up3.start()
p3 = subprocess.Popen([BINARY,'-r','-l','127.0.0.1:29321',
                        '--upstream','127.0.0.1:29320','-k','correct'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.3)
resp = udp_exchange(29321, make_obfs_quic('wrong',b'bad'))
time.sleep(0.2)
p3.terminate(); p3.wait(2); up3.stop()
check('릴레이 잘못된 키 → upstream 미전달', len(up3.pkts)==0)
check('릴레이 잘못된 키 → QUIC Initial 응답', is_quic_initial(resp))

# TC4: 키별 라우팅
upA = UDPListener(29331); upA.start()
upB = UDPListener(29332); upB.start()
p4 = subprocess.Popen([BINARY,'-r','-l','127.0.0.1:29330',
                        '--route','keyA 127.0.0.1:29331',
                        '--route','keyB 127.0.0.1:29332'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.3)
sA = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sA.bind(('127.0.0.1',0))
sB = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); sB.bind(('127.0.0.1',0))
sA.sendto(make_obfs_quic('keyA',b'forA'), ('127.0.0.1',29330))
sB.sendto(make_obfs_quic('keyB',b'forB'), ('127.0.0.1',29330))
sA.close(); sB.close()
time.sleep(0.3)
p4.terminate(); p4.wait(2); upA.stop(); upB.stop()
check('키별 라우팅: keyA → upstream A', len(upA.pkts)>0)
check('키별 라우팅: keyB → upstream B', len(upB.pkts)>0)

# TC5: decoy 포워딩
decoy_pkts = []
def decoy_srv():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    s.bind(('127.0.0.1',29341)); s.settimeout(3)
    try:
        while True:
            d,a = s.recvfrom(4096); decoy_pkts.append(d)
            s.sendto(b'decoy-ok', a)
    except: pass
    s.close()
dt = threading.Thread(target=decoy_srv, daemon=True); dt.start(); time.sleep(0.1)
p5 = subprocess.Popen([BINARY,'-r','-l','127.0.0.1:29340',
                        '--upstream','127.0.0.1:9999','-k','key',
                        '--decoy','127.0.0.1:29341'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.3)
resp5 = udp_exchange(29340, b'\x00'*50)
time.sleep(0.3)
p5.terminate(); p5.wait(2)
check('decoy: HMAC 실패 → decoy 서버 수신', len(decoy_pkts)>0)
check('decoy: decoy 응답 클라이언트에 중계', resp5==b'decoy-ok')

# ═══════════════════════════════════════════════════════════════════════════════
print('\n[6] obfs 모드별 프로브 응답')
# ═══════════════════════════════════════════════════════════════════════════════

# quic 모드 → QUIC Initial
p6 = subprocess.Popen([BINARY,'-r','-l','127.0.0.1:29400',
                        '--upstream','127.0.0.1:9999','-k','key','--obfs-mode','quic'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.3)
resp6 = udp_exchange(29400, b'\x00'*50)
p6.terminate(); p6.wait(2)
check('obfs-mode quic: HMAC 실패 → QUIC Initial', is_quic_initial(resp6))

# tls 모드 → close_notify
p7 = subprocess.Popen([BINARY,'-r','-l','127.0.0.1:29401',
                        '--upstream','127.0.0.1:9999','-k','key','--obfs-mode','tls'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.3)
resp7 = udp_exchange(29401, b'\x00'*50)
p7.terminate(); p7.wait(2)
check('obfs-mode tls: HMAC 실패 → TLS close_notify', resp7==TLS_CLOSE_NOTIFY)

# QUIC Initial 크기 다양성
p8 = subprocess.Popen([BINARY,'-r','-l','127.0.0.1:29402',
                        '--upstream','127.0.0.1:9999','-k','key'],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.3)
sizes = set()
for _ in range(8):
    r = udp_exchange(29402, b'\x00'*50, timeout=0.5)
    if r: sizes.add(len(r))
    time.sleep(0.05)
p8.terminate(); p8.wait(2)
check('QUIC Initial 응답 크기 다양성 (rand)', len(sizes)>1, f'sizes={sorted(sizes)}')
check('QUIC Initial 응답 크기 ≥1200B', all(s>=1200 for s in sizes) if sizes else False)

# ═══════════════════════════════════════════════════════════════════════════════
print('\n[7] auth-interval 슬롯 검증')
# ═══════════════════════════════════════════════════════════════════════════════

for interval in [30, 60]:
    up_ai = UDPListener(29500+interval); up_ai.start()
    p_ai = subprocess.Popen([BINARY,'-r','-l',f'127.0.0.1:{29501+interval}',
                              '--upstream',f'127.0.0.1:{29500+interval}',
                              '-k','aikey','--auth-interval',str(interval)],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.3)
    psk = derive_psk('aikey')
    slot = int(time.time())//interval
    h = siphash24(struct.pack('<Q',slot), psk)
    token = struct.pack('<Q',h)
    pkt = bytearray(300)
    pkt[0]=0x40|(token[0]&0x3F); pkt[1:8]=token[1:8]; pkt[8]=token[0]; pkt[9]=0
    pkt[10:15]=b'hello'
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.sendto(bytes(pkt), ('127.0.0.1',29501+interval)); s.close()
    time.sleep(0.3)
    p_ai.terminate(); p_ai.wait(2); up_ai.stop()
    check(f'auth-interval {interval}: 올바른 슬롯 패킷 전달', len(up_ai.pkts)>0)

# ═══════════════════════════════════════════════════════════════════════════════
print('\n[8] FIFO 런타임 커맨드')
# ═══════════════════════════════════════════════════════════════════════════════

fifo = '/tmp/mf_test_fifo'
try: os.unlink(fifo)
except: pass
os.mkfifo(fifo)
p_f = subprocess.Popen([BINARY,'-r','-l','127.0.0.1:29600',
                         '--upstream','127.0.0.1:9999','--disable-obfs',
                         '--fifo',fifo],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
time.sleep(0.3)
alive_before = p_f.poll() is None
try:
    fd = os.open(fifo, os.O_WRONLY|os.O_NONBLOCK)
    os.write(fd, b'mtu 1300\n'); os.close(fd)
except: pass
time.sleep(0.2)
alive_after = p_f.poll() is None
p_f.terminate(); p_f.wait(2)
try: os.unlink(fifo)
except: pass
check('--fifo 시작', alive_before)
check('FIFO 커맨드 후 크래시 없음', alive_after)

# ═══════════════════════════════════════════════════════════════════════════════
print(f'\n{"="*60}')
total = PASS+FAIL
print(f'결과: {PASS}/{total} 통과  ' +
      ('✓ 전체 통과' if FAIL==0 else f'✗ {FAIL}개 실패'))

if FAIL > 0:
    print('\n실패 항목:')
    for st,name,detail in results:
        if st=='FAIL':
            print(f'  ✗ {name}' + (f'  [{detail}]' if detail else ''))

sys.exit(0 if FAIL==0 else 1)
