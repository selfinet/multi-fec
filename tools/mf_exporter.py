#!/usr/bin/env python3
"""mf_exporter — multi-fec Prometheus exporter (stdlib only, Python 3.9+).

multi-fec 에는 통계 API 가 없다. 이 exporter 는 두 가지를 합친다:
  1) journald 를 따라가며 multi-fec 로그 줄을 파싱 (경로 상태·report 카운터·이벤트)
  2) 스크레이프 시점에 /proc · systemctl · wg 를 읽는다 (프로세스·소켓 드롭·터널)

읽기 전용이다. conf 파일(PSK 포함)은 읽지 않는다.

사용:
  mf_exporter.py --listen 10.9.20.2:9477 --unit multi-fec-client
  mf_exporter.py --listen 0.0.0.0:9477 --unit multi-fec-relay --unit multi-fec-relay-b
  mf_exporter.py --replay saved.log      # 저장된 journal 텍스트로 파서만 검증, 메트릭 출력 후 종료
"""
import argparse
import json
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ANSI = re.compile(r'\x1b\[[0-9;]*m')
LEVEL = re.compile(r'\]\[(FATAL|ERROR|WARN|INFO|DEBUG|TRACE)\]')

# v1.3.3+ "owd=26.16ms jit=0.20ms", v1.3.2 이하 "rtt=26us jit=0us" (값은 이미 ms 였다 — CLAUDE.md §4)
PATH_RE = re.compile(
    r'\[client\] path\[(\d+)\] (\w+) '
    r'(?:owd=([\d.]+)ms jit=([\d.]+)ms|rtt=(\d+)us jit=(\d+)us) '
    r'loss=(\d+)% rate=([\d.]+)Mbps tx=(\d+) rx=(\d+)')
# 클라이언트: "[report]client-->..."  서버: "[report][addr]client-->..."  (fec 뒤 구분자가 ',' 또는 ';')
REPORT_RE = re.compile(
    r'\[report\](?:\[([^\]]+)\])?client-->server:'
    r'\(original:(\d+) pkt;(\d+) byte\) \(fec:(\d+) pkt[,;](\d+) byte\)\s+server-->client:'
    r'\(original:(\d+) pkt;(\d+) byte\) \(fec:(\d+) pkt;(\d+) byte\)')
EVENTS = [  # (메트릭 이름, 정규식, 건수 그룹 — None 이면 1건)
    ('server_new_client',      re.compile(r'\[server\] new client '), None),
    ('server_new_session',     re.compile(r'\[server\] (?:totp: )?new session [0-9a-f]{16} '), None),
    ('relay_new_session',      re.compile(r'\[relay\] new session: '), None),
    ('decoy_new_session',      re.compile(r'\[(?:relay/)?decoy\] new session prober='), None),
    ('stale_pending_dropped',  re.compile(r'dropped (\d+) stale pending packet'), 1),
    ('path_table_full_dropped', re.compile(r'경로 테이블 소진 \(상한 \d+\) — 최근 주기에 (\d+) 건'), 1),
    ('sockbuf_capped',         re.compile(r'sock-buf=\d+ kB (?:requested but kernel )?capped'), None),
]
STATUS = ['DELETING', 'PROBING', 'DEGRADED', 'LOSSY', 'WAITING', 'READY', 'RUNNING']
SERIES_TTL = 600  # 이 시간 동안 갱신 없는 경로·피어 시리즈는 내보내지 않는다 (서버 피어 포트가 바뀌므로)


class State:
    def __init__(self):
        self.lock = threading.Lock()
        self.paths = {}    # (unit, idx) -> dict
        self.reports = {}  # (unit, peer) -> (ts, [8 values])
        self.events = {}   # (unit, name) -> count
        self.levels = {}   # (unit, level) -> count
        self.lines = 0
        self.last_line_ts = 0.0

    def feed(self, unit, msg, ts=None):
        msg = ANSI.sub('', msg)
        ts = ts or time.time()
        with self.lock:
            self.lines += 1
            self.last_line_ts = ts
            m = LEVEL.search(msg)
            if m:
                k = (unit, m.group(1))
                self.levels[k] = self.levels.get(k, 0) + 1
            m = PATH_RE.search(msg)
            if m:
                idx, st, owd, jit, rtt_old, jit_old, loss, rate, tx, rx = m.groups()
                self.paths[(unit, idx)] = dict(
                    ts=ts, status=st,
                    owd=float(owd if owd is not None else rtt_old),
                    jit=float(jit if jit is not None else jit_old),
                    loss=int(loss), rate=float(rate), tx=int(tx), rx=int(rx))
                return
            m = REPORT_RE.search(msg)
            if m:
                peer = m.group(1) or ''
                self.reports[(unit, peer)] = (ts, [int(x) for x in m.groups()[1:]])
                return
            for name, rx_, grp in EVENTS:
                m = rx_.search(msg)
                if m:
                    k = (unit, name)
                    self.events[k] = self.events.get(k, 0) + (int(m.group(grp)) if grp else 1)
                    return


def follow_journal(state, units):
    """journalctl -f 를 계속 따라간다. 죽으면 5초 뒤 재시작 (-n 0: 과거 줄은 다시 세지 않는다)."""
    cmd = ['journalctl', '-f', '-n', '0', '-o', 'json', '--no-pager']
    for u in units:
        cmd += ['-u', u]
    while True:
        try:
            p = subprocess.Popen(cmd, stdout=subprocess.PIPE, text=True, errors='replace')
            for line in p.stdout:
                try:
                    j = json.loads(line)
                except ValueError:
                    continue
                msg = j.get('MESSAGE')
                if isinstance(msg, list):  # 비 UTF-8 이면 바이트 배열로 온다
                    msg = bytes(msg).decode('utf-8', 'replace')
                if msg:
                    unit = (j.get('_SYSTEMD_UNIT') or '').removesuffix('.service')
                    state.feed(unit, msg)
            p.wait()
        except Exception as e:  # noqa: BLE001 — 수집기가 죽으면 안 된다
            print(f'journal follower error: {e}', file=sys.stderr)
        time.sleep(5)


def run(cmd):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=3).stdout
    except Exception:  # noqa: BLE001
        return ''


def udp_socket_drops():
    """inode -> drops (/proc/net/udp, udp6 마지막 열)."""
    out = {}
    for f in ('/proc/net/udp', '/proc/net/udp6'):
        try:
            with open(f) as fh:
                next(fh)
                for ln in fh:
                    c = ln.split()
                    out[c[9]] = int(c[-1])
        except OSError:
            pass
    return out


_version_cache = {}


def binary_version(pid):
    try:
        exe = os.readlink(f'/proc/{pid}/exe')
        st = os.stat(f'/proc/{pid}/exe')
    except OSError:
        return ''
    if not os.path.basename(exe).startswith('multi-fec'):  # 다른 프로그램을 --version 으로 실행하지 않는다
        return ''
    key = (exe, st.st_ino, st.st_mtime)
    if key not in _version_cache:  # 실행 중 프로세스의 바이너리로 묻는다 (PATH 상의 다른 바이너리 아님)
        first = run([f'/proc/{pid}/exe', '--version']).splitlines()
        _version_cache[key] = first[0].split()[-1] if first else ''
    return _version_cache[key]


def unit_metrics(units, out):
    drops = udp_socket_drops()
    for u in units:
        props = dict(l.split('=', 1) for l in run(
            ['systemctl', 'show', u, '-p', 'MainPID', '-p', 'ActiveState', '-p', 'NRestarts',
             '-p', 'UnitFileState']).splitlines() if '=' in l)
        lab = f'unit="{u}"'
        out.append(f'mf_unit_active{{{lab}}} {int(props.get("ActiveState") == "active")}')
        out.append(f'mf_unit_enabled{{{lab}}} {int(props.get("UnitFileState") == "enabled")}')
        out.append(f'mf_unit_restarts_total{{{lab}}} {props.get("NRestarts", "0") or 0}')
        pid = props.get('MainPID', '0')
        if pid in ('', '0'):
            continue
        try:
            with open(f'/proc/{pid}/status') as fh:
                rss = next(int(l.split()[1]) * 1024 for l in fh if l.startswith('VmRSS:'))
            fds = os.listdir(f'/proc/{pid}/fd')
            start_ticks = int(open(f'/proc/{pid}/stat').read().rsplit(')', 1)[1].split()[19])
        except (OSError, StopIteration, ValueError):
            continue
        sock_drops = 0
        for fd in fds:
            try:
                t = os.readlink(f'/proc/{pid}/fd/{fd}')
            except OSError:
                continue
            if t.startswith('socket:['):
                sock_drops += drops.get(t[8:-1], 0)
        boot = float(open('/proc/stat').read().split('btime ')[1].split()[0])
        started = boot + start_ticks / os.sysconf('SC_CLK_TCK')
        out.append(f'mf_process_rss_bytes{{{lab}}} {rss}')
        out.append(f'mf_process_open_fds{{{lab}}} {len(fds)}')
        out.append(f'mf_process_start_time_seconds{{{lab}}} {started:.0f}')
        out.append(f'mf_process_socket_drops{{{lab}}} {sock_drops}')
        v = binary_version(pid)
        out.append(f'mf_build_info{{{lab},version="{v}"}} 1')


def host_metrics(out):
    try:
        lines = [l.split() for l in open('/proc/net/snmp') if l.startswith('Udp:')]
        hdr, val = lines[0][1:], lines[1][1:]
        for k in ('InErrors', 'RcvbufErrors', 'SndbufErrors'):
            if k in hdr:
                out.append(f'mf_host_udp_{k.lower()}_total {val[hdr.index(k)]}')
    except (OSError, IndexError):
        pass
    # wg show all dump: 인터페이스 줄(5필드)과 피어 줄(9필드). 피어 공개키는 앞 8자만 라벨로 쓴다.
    for ln in run(['wg', 'show', 'all', 'dump']).splitlines():
        c = ln.split('\t')
        if len(c) == 9:
            lab = f'iface="{c[0]}",peer="{c[1][:8]}"'
            out.append(f'mf_wg_latest_handshake_seconds{{{lab}}} {c[5]}')
            out.append(f'mf_wg_rx_bytes_total{{{lab}}} {c[6]}')
            out.append(f'mf_wg_tx_bytes_total{{{lab}}} {c[7]}')


def render(state, units, live=True):
    out = []
    now = time.time()
    with state.lock:
        out.append('# HELP mf_path_status 클라이언트 경로 상태 (로그 30초 주기, 해당 상태면 1)')
        out.append('# TYPE mf_path_status gauge')
        for (u, i), p in sorted(state.paths.items()):
            if live and now - p['ts'] > SERIES_TTL:
                continue
            lab = f'unit="{u}",path="{i}"'
            for s in STATUS:
                out.append(f'mf_path_status{{{lab},status="{s}"}} {int(p["status"] == s)}')
            out.append(f'mf_path_owd_ms{{{lab}}} {p["owd"]}')
            out.append(f'mf_path_jitter_ms{{{lab}}} {p["jit"]}')
            out.append(f'mf_path_loss_percent{{{lab}}} {p["loss"]}')
            out.append(f'mf_path_rate_mbps{{{lab}}} {p["rate"]}')
            out.append(f'mf_path_tx_packets_total{{{lab}}} {p["tx"]}')
            out.append(f'mf_path_rx_packets_total{{{lab}}} {p["rx"]}')
            out.append(f'mf_path_last_report_timestamp_seconds{{{lab}}} {p["ts"]:.0f}')
        out.append('# HELP mf_report_* --report 누적값. 프로세스·연결이 새로 생기면 0 부터 (rate() 로 본다)')
        names = ['up_original_packets', 'up_original_bytes', 'up_fec_packets', 'up_fec_bytes',
                 'down_original_packets', 'down_original_bytes', 'down_fec_packets', 'down_fec_bytes']
        for (u, peer), (ts, vals) in sorted(state.reports.items()):
            if live and now - ts > SERIES_TTL:
                continue
            lab = f'unit="{u}",peer="{peer}"'
            for n, v in zip(names, vals):
                out.append(f'mf_report_{n}_total{{{lab}}} {v}')
        for (u, n), v in sorted(state.events.items()):
            out.append(f'mf_event_{n}_total{{unit="{u}"}} {v}')
        for (u, lv), v in sorted(state.levels.items()):
            out.append(f'mf_log_lines_total{{unit="{u}",level="{lv}"}} {v}')
        out.append(f'mf_exporter_lines_total {state.lines}')
        out.append(f'mf_exporter_last_line_timestamp_seconds {state.last_line_ts:.0f}')
    if live:
        unit_metrics(units, out)
        host_metrics(out)
    return '\n'.join(out) + '\n'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--listen', default='127.0.0.1:9477', help='관리망 IP 로만 열 것 (공인 IP 금지)')
    ap.add_argument('--unit', action='append', default=[], help='감시할 systemd 유닛 (반복)')
    ap.add_argument('--replay', help='journal 텍스트 파일을 파싱해 메트릭을 출력하고 종료')
    a = ap.parse_args()
    state = State()

    if a.replay:
        unit_re = re.compile(r' (multi-fec[\w@.-]*)\[\d+\]: | (multi-fec[\w@.-]*) multi-fec-dist\[\d+\]: ')
        with open(a.replay, errors='replace') as fh:
            for ln in fh:
                m = unit_re.search(ln)
                state.feed((m.group(1) or m.group(2)) if m else 'replay', ln)
        sys.stdout.write(render(state, [], live=False))
        return

    if not a.unit:
        ap.error('--unit 을 하나 이상 지정')
    threading.Thread(target=follow_journal, args=(state, a.unit), daemon=True).start()

    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != '/metrics':
                self.send_error(404)
                return
            body = render(state, a.unit).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; version=0.0.4; charset=utf-8')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    host, port = a.listen.rsplit(':', 1)
    ThreadingHTTPServer((host, int(port)), H).serve_forever()


if __name__ == '__main__':
    main()
