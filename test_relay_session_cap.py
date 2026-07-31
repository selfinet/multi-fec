#!/usr/bin/env python3
"""
test_relay_session_cap.py — 릴레이 동시 세션 상한 회귀 방지 (CLAUDE.md §22-나)

릴레이는 클라이언트 (src_ip, src_port) 마다 upstream 소켓 + ev_io watcher 를 하나씩
잡는다. idle 만료(60초)만으로는 소스 포트를 계속 바꿔가며 보내는 트래픽을 막지
못해 만료 전에 FD 가 고갈됐다. RELAY_SESSION_MAX(=max_conn_num*4=800) + LRU 축출이
들어간 뒤, 세션 수가 상한 안에서 유지되고 릴레이가 계속 서비스하는지 확인한다.

수정 전 바이너리로 돌리면 FD 가 RLIMIT_NOFILE 까지 차서
"upstream socket 생성 실패"로 신규 세션을 못 만드는 상태에 갇힌다.

사용:
    python3 test_relay_session_cap.py                  # 수정 후 바이너리
    BIN=/path/to/old-binary python3 test_relay_session_cap.py   # A/B 비교
"""
import os
import socket
import subprocess
import sys
import time

BIN = os.environ.get("BIN", "./multi-fec")
RELAY_PORT = 24443
UPSTREAM_PORT = 24444
# 상한(800)을 확실히 넘기되 RLIMIT_NOFILE(보통 1024) 도 넘기도록 잡는다.
N_PORTS = 1000
CAP = 800          # RELAY_SESSION_MAX = max_conn_num(200) * 4
CAP_SLACK = 40     # 리슨 소켓·타이머·표준 FD 등 세션 외 몫

passed = failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ✓ {name} {detail}")
    else:
        failed += 1
        print(f"  ✗ {name} {detail}")


def fd_count(pid):
    try:
        return len(os.listdir(f"/proc/{pid}/fd"))
    except OSError:
        return -1


def drain(sock, into):
    """sink 를 비워 둔다. 비우지 않으면 SO_RCVBUF 가 넘쳐 뒤 패킷이 유실되고
    상한 도달 후 서비스 여부를 잘못 판정한다(실제로 한 번 겪었다)."""
    while True:
        try:
            into.append(sock.recvfrom(2048)[0])
        except BlockingIOError:
            return
        except OSError:
            return


def main():
    # upstream sink
    sink = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sink.bind(("127.0.0.1", UPSTREAM_PORT))
    sink.setblocking(False)

    # 투명 중계 모드(-k 없음): HMAC 검증이 없어 아무 바이트나 세션을 만든다.
    proc = subprocess.Popen(
        [BIN, "-r", "-l", f"127.0.0.1:{RELAY_PORT}",
         "--upstream", f"127.0.0.1:{UPSTREAM_PORT}", "--log-level", "2"],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.7)
    if proc.poll() is not None:
        print("relay 기동 실패")
        return 1

    try:
        base_fd = fd_count(proc.pid)
        print(f"[1] 기준 FD = {base_fd}")

        # 서로 다른 소스 포트 N_PORTS 개에서 1패킷씩 — 세션 N_PORTS 개 요구
        seen = []
        socks = []
        for _ in range(N_PORTS):
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.bind(("127.0.0.1", 0))
            s.setblocking(False)
            try:
                s.sendto(b"x" * 64, ("127.0.0.1", RELAY_PORT))
            except OSError:
                pass
            socks.append(s)
            drain(sink, seen)
            time.sleep(0.001)      # 릴레이가 처리할 틈을 준다
        time.sleep(1.0)
        drain(sink, seen)

        peak_fd = fd_count(proc.pid)
        sessions = peak_fd - base_fd
        print(f"[2] {N_PORTS} 소스포트 전송 후 FD = {peak_fd} (세션 ≈ {sessions})")

        check("릴레이 생존", proc.poll() is None)
        check(f"세션 수가 상한({CAP}) 안에서 유지",
              sessions <= CAP + CAP_SLACK, f"[{sessions} <= {CAP + CAP_SLACK}]")
        # 요구한 만큼 무제한으로 늘지 않아야 한다. 수정 전 바이너리는 여기서
        # N_PORTS 개를 그대로 만든다(FD 여유가 없는 환경에서는 고갈로 이어진다).
        check("요청한 세션 수만큼 무제한 증가하지 않음",
              sessions < N_PORTS, f"[{sessions} < {N_PORTS}]")

        # 상한에 걸린 뒤에도 신규 클라이언트를 계속 서비스해야 한다 (LRU 축출)
        fresh = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        fresh.bind(("127.0.0.1", 0))
        fresh.settimeout(1.0)
        fresh.sendto(b"fresh-after-cap", ("127.0.0.1", RELAY_PORT))
        time.sleep(0.4)

        got = []
        drain(sink, got)
        check("상한 도달 후에도 신규 세션 서비스됨 (LRU 축출)",
              b"fresh-after-cap" in got,
              f"[상한 후 upstream 수신 {len(got)}패킷 / 누적 {len(seen)}]")

        for s in socks:
            s.close()
        fresh.close()
    finally:
        proc.terminate()
        try:
            proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            proc.kill()
        sink.close()

    print(f"\n결과: {passed}/{passed + failed} 통과 "
          f"{'✓' if failed == 0 else '✗'}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
