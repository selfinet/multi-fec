#!/usr/bin/env python3
"""
키별 릴레이 라우팅 통합 테스트

구성:
  upstream A (9001) ← keyA 패킷만 도달해야 함
  upstream B (9002) ← keyB 패킷만 도달해야 함
  릴레이     (9000) : --route "keyA 127.0.0.1:9001" --route "keyB 127.0.0.1:9002"

테스트 케이스:
  1. keyA 패킷 → upstream A 도달, upstream B 미도달
  2. keyB 패킷 → upstream B 도달, upstream A 미도달
  3. 잘못된 키 패킷 → TLS close_notify 수신
  4. 투명 패킷(obfs 없음) → close_notify 수신
"""

import socket
import struct
import time
import subprocess
import threading
import sys
import os
import signal

# ─── SipHash-2-4 ────────────────────────────────────────────────────────────

M64 = 0xFFFFFFFFFFFFFFFF

def rotl64(v, n):
    return ((v << n) | (v >> (64 - n))) & M64

def sipround(v0, v1, v2, v3):
    v0 = (v0 + v1) & M64; v1 = rotl64(v1, 13); v1 ^= v0; v0 = rotl64(v0, 32)
    v2 = (v2 + v3) & M64; v3 = rotl64(v3, 16); v3 ^= v2
    v0 = (v0 + v3) & M64; v3 = rotl64(v3, 21); v3 ^= v0
    v2 = (v2 + v1) & M64; v1 = rotl64(v1, 17); v1 ^= v2; v2 = rotl64(v2, 32)
    return v0, v1, v2, v3

def siphash24(data: bytes, key: bytes) -> int:
    k0, k1 = struct.unpack_from('<QQ', key)
    v0 = (k0 ^ 0x736f6d6570736575) & M64
    v1 = (k1 ^ 0x646f72616e646f6d) & M64
    v2 = (k0 ^ 0x6c7967656e657261) & M64
    v3 = (k1 ^ 0x7465646279746573) & M64

    length = len(data)
    blocks = length // 8
    for i in range(blocks):
        m = struct.unpack_from('<Q', data, i * 8)[0]
        v3 ^= m
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
        v0 ^= m

    b = (length & M64) << 56
    last = data[blocks * 8:]
    for i, byte in enumerate(last):
        b |= (byte << (i * 8))
    b &= M64

    v3 ^= b
    v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
    v0, v1, v2, v3 = sipround(v0, v1, v2, v3)
    v0 ^= b

    v2 ^= 0xff
    for _ in range(4):
        v0, v1, v2, v3 = sipround(v0, v1, v2, v3)

    return (v0 ^ v1 ^ v2 ^ v3) & M64

# ─── PSK 파생 (obfs.cpp derive_psk 동일 로직) ───────────────────────────────

DERIV_KEY = bytes([
    0x6d, 0x75, 0x6c, 0x74, 0x69, 0x2d, 0x66, 0x65,
    0x63, 0x2d, 0x70, 0x73, 0x6b, 0x2d, 0x76, 0x31
])

def derive_psk(key_str: str) -> bytes:
    kb = key_str.encode()
    h0 = siphash24(kb, DERIV_KEY)
    h1 = siphash24(kb + b'\x01', DERIV_KEY)
    return struct.pack('<QQ', h0, h1)  # 16 bytes

# ─── obfs QUIC 패킷 생성 ─────────────────────────────────────────────────────

AUTH_INTERVAL = 30  # 초

def make_obfs_quic_packet(key_str: str, payload: bytes) -> bytes:
    psk  = derive_psk(key_str)
    slot = int(time.time()) // AUTH_INTERVAL
    h    = siphash24(struct.pack('<Q', slot), psk)
    token = struct.pack('<Q', h)  # 8 bytes little-endian

    OBFS_HEADER_QUIC = 10
    raw_total = OBFS_HEADER_QUIC + len(payload)
    buckets = [300, 500, 700, 900, 1100, 1300]
    bucket  = next((b for b in buckets if b >= raw_total), raw_total)
    pad_len = bucket - raw_total
    if pad_len < 0:
        pad_len = 0
    if pad_len > 245:       # OBFS_MAX_PADDING
        pad_len = 245

    pkt = bytearray(OBFS_HEADER_QUIC + len(payload) + pad_len)
    pkt[0] = 0x40 | (token[0] & 0x3F)   # pkt_type=0 (DATA)
    pkt[1:8] = token[1:8]
    pkt[8]   = token[0]
    pkt[9]   = pad_len
    pkt[10:10+len(payload)] = payload
    # 패딩: 0으로 채움 (랜덤 불필요, HMAC 검증에 무관)
    return bytes(pkt)

# ─── UDP 수신 헬퍼 ───────────────────────────────────────────────────────────

def udp_recv_once(sock: socket.socket, timeout: float) -> bytes | None:
    sock.settimeout(timeout)
    try:
        data, _ = sock.recvfrom(4096)
        return data
    except socket.timeout:
        return None

# ─── upstream 리스너 (스레드) ─────────────────────────────────────────────────

class UpstreamListener:
    def __init__(self, port: int, label: str):
        self.port    = port
        self.label   = label
        self.packets = []
        self._sock   = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self._sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self._sock.bind(('127.0.0.1', port))
        self._sock.settimeout(0.2)
        self._stop   = threading.Event()
        self._thread = threading.Thread(target=self._run, daemon=True)

    def start(self):
        self._thread.start()

    def _run(self):
        while not self._stop.is_set():
            try:
                data, addr = self._sock.recvfrom(4096)
                self.packets.append(data)
            except socket.timeout:
                pass

    def stop(self):
        self._stop.set()
        self._thread.join(timeout=1)
        self._sock.close()

    def count(self) -> int:
        return len(self.packets)

# ─── 테스트 메인 ─────────────────────────────────────────────────────────────

RELAY_ADDR = ('127.0.0.1', 9000)
TLS_CLOSE_NOTIFY = bytes([0x15, 0x03, 0x03, 0x00, 0x02, 0x01, 0x00])
QUIC_INITIAL_SIZE = 1200
def is_quic_server_initial(data: bytes) -> bool:
    """QUIC Long Header Initial (Server) 판별: 0xC1, QUIC v1, SCID[0]=0xFF
    크기는 1200B 이상 (0-255B 랜덤 패딩으로 가변)"""
    return (len(data) >= QUIC_INITIAL_SIZE and
            data[0] == 0xC1 and
            data[1:5] == b'\x00\x00\x00\x01' and   # QUIC v1
            data[5] == 0x08 and                      # DCID len=8
            data[14] == 0x08 and                     # SCID len=8
            data[15] == 0xFF)                        # Server Initial marker

def run_tests(relay_proc):
    # upstream 리스너 시작
    ua = UpstreamListener(9001, 'upstreamA(keyA)')
    ub = UpstreamListener(9002, 'upstreamB(keyB)')
    ua.start()
    ub.start()

    # 송신 소켓
    tx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tx.bind(('127.0.0.1', 0))

    results = []

    def check(name, cond):
        mark = '✓' if cond else '✗'
        results.append(cond)
        print(f'  {mark}  {name}')

    # ── TC1: keyA 패킷 → upstream A만 도달 ──────────────────────────────────
    print('\n[TC1] keyA 패킷 → upstream A 라우팅')
    pkt_a = make_obfs_quic_packet('keyA', b'hello-from-keyA')
    for _ in range(3):
        tx.sendto(pkt_a, RELAY_ADDR)
    time.sleep(0.3)
    check('upstream A 수신 > 0', ua.count() > 0)
    cnt_b_before = ub.count()
    check('upstream B 수신 = 0', cnt_b_before == 0)
    print(f'     A={ua.count()} pkt, B={ub.count()} pkt')

    # ── TC2: keyB 패킷 → upstream B만 도달 ──────────────────────────────────
    # 주의: 릴레이는 (src_ip, src_port) 단위로 세션을 고정하므로
    #        TC1과 다른 소켓(다른 ephemeral port)에서 보내야 한다.
    print('\n[TC2] keyB 패킷 → upstream B 라우팅 (별도 소켓)')
    ua_before = ua.count()
    tx_b = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    tx_b.bind(('127.0.0.1', 0))
    pkt_b = make_obfs_quic_packet('keyB', b'hello-from-keyB')
    for _ in range(3):
        tx_b.sendto(pkt_b, RELAY_ADDR)
    time.sleep(0.3)
    check('upstream B 수신 증가', ub.count() > 0)
    check('upstream A 추가 수신 없음', ua.count() == ua_before)
    print(f'     A={ua.count()} pkt, B={ub.count()} pkt')
    tx_b.close()

    # ── TC3: 잘못된 키 → 내장 QUIC Server Initial ────────────────────────────
    print('\n[TC3] 잘못된 키(keyC) → 내장 QUIC Server Initial')
    rx = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    rx.bind(('127.0.0.1', 0))
    rx.settimeout(1.0)
    pkt_bad = make_obfs_quic_packet('keyC', b'bad-key-packet')
    rx.sendto(pkt_bad, RELAY_ADDR)
    resp = udp_recv_once(rx, timeout=1.0)
    check('QUIC Server Initial 수신 (≥1200B)', resp is not None and is_quic_server_initial(resp))
    if resp:
        print(f'     크기={len(resp)}B  첫바이트=0x{resp[0]:02x}  SCID[0]=0x{resp[15]:02x}')
    else:
        print('     응답 없음')

    # ── TC4: 투명 raw 패킷 → 내장 QUIC Server Initial ───────────────────────
    print('\n[TC4] raw 패킷(obfs 없음) → 내장 QUIC Server Initial')
    raw_pkt = b'\x00' * 100
    rx.sendto(raw_pkt, RELAY_ADDR)
    resp2 = udp_recv_once(rx, timeout=1.0)
    check('QUIC Server Initial 수신 (≥1200B)', resp2 is not None and is_quic_server_initial(resp2))
    if resp2:
        print(f'     크기={len(resp2)}B  첫바이트=0x{resp2[0]:02x}  SCID[0]=0x{resp2[15]:02x}')
    else:
        print('     응답 없음')

    # ── TC5: 기존 keyA 세션 → 연속 패킷 처리 ────────────────────────────────
    print('\n[TC5] keyA 세션 연속 10패킷')
    a_before = ua.count()
    for i in range(10):
        pkt = make_obfs_quic_packet('keyA', f'seq-{i}'.encode())
        tx.sendto(pkt, RELAY_ADDR)
    time.sleep(0.5)
    added = ua.count() - a_before
    check(f'upstream A 10패킷 수신 (got {added})', added == 10)

    # 정리
    rx.close()
    tx.close()
    ua.stop()
    ub.stop()

    passed = sum(results)
    total  = len(results)
    print(f'\n결과: {passed}/{total} 통과', '✓' if passed == total else '✗ 일부 실패')
    return passed == total

def main():
    bin_path = os.path.join(os.path.dirname(__file__), 'multi-fec')
    if not os.path.exists(bin_path):
        print('오류: multi-fec 바이너리 없음')
        sys.exit(1)

    print('릴레이 시작 중...')
    relay = subprocess.Popen(
        [bin_path, '-r', '-l', '127.0.0.1:9000',
         '--route', 'keyA 127.0.0.1:9001',
         '--route', 'keyB 127.0.0.1:9002',
         '--log-level', '4'],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT
    )

    time.sleep(0.4)  # 릴레이 준비 대기

    if relay.poll() is not None:
        out, _ = relay.communicate()
        print('릴레이 시작 실패:')
        print(out.decode())
        sys.exit(1)

    print(f'릴레이 PID={relay.pid}')

    try:
        ok = run_tests(relay)
    finally:
        relay.terminate()
        try:
            relay.wait(timeout=2)
        except subprocess.TimeoutExpired:
            relay.kill()

    sys.exit(0 if ok else 1)

if __name__ == '__main__':
    main()
