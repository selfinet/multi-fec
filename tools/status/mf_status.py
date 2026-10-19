#!/usr/bin/env python3
"""mf_status.py — multi-fec 상태 중앙 서버 + 대시보드 (2026-10-19, 테스트망 전용 — 서비스망 적용 금지)

  mf_status.py --listen 127.0.0.1:8780 --db /var/lib/mf-status/status.db --tokens /etc/mf-status/tokens

에이전트(mf_agent.py)가 POST /api/push 로 보낸 상태를 SQLite 에 저장하고, 규칙으로 이벤트를 만들고,
대시보드(GET /)와 API 를 제공한다. Python 3.8+ 표준 라이브러리만 쓴다.

tokens 파일: 한 줄에 `호스트명 토큰`. 토큰이 호스트를 정한다 — 문서의 host 값과 다르면 거부한다(다른 호스트 사칭 방지).
API: GET /api/status · /api/history?host=&unit=&series=&hours= · /api/events?limit= · POST /api/push
보기 전용이다 — 대시보드에서 아무것도 바꿀 수 없다. 인증 없는 GET 이므로 루프백이나 신뢰 구간에만 연다.
"""
import argparse, hmac, json, os, sqlite3, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

STALE_SEC = 90          # 이 시간 넘게 push 가 없으면 호스트 정지로 본다
PATH_BAD_SEC = 120      # 경로가 RUNNING 이 아닌 상태가 이만큼 이어지면 경보
BRANCH_GONE_SEC = 120   # 지사(키)가 늘 보이던 relay 에서 세션이 이만큼 없으면 경보 (relay 는 60초 무통신이면 세션을 지운다)
BRANCH_FORGET_SEC = 86400   # 이 시간 넘게 안 보인 지사·relay 조합은 감시 대상에서 뺀다
WG_HS_SEC = 180         # WireGuard 마지막 핸드셰이크가 이보다 오래면 경보 (정상은 2분 이내 갱신)
KEEP_DAYS = 7
MAX_BODY = 512 * 1024


class Store:
    def __init__(self, path):
        self.db = sqlite3.connect(path, check_same_thread=False)
        self.lock = threading.Lock()
        self.db.executescript('''
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS latest (host TEXT PRIMARY KEY, ts INTEGER, recv INTEGER, doc TEXT);
            CREATE TABLE IF NOT EXISTS samples (host TEXT, ts INTEGER, doc TEXT);
            CREATE INDEX IF NOT EXISTS samples_ht ON samples(host, ts);
            CREATE TABLE IF NOT EXISTS events (ts INTEGER, host TEXT, level TEXT, key TEXT, msg TEXT);
            CREATE INDEX IF NOT EXISTS events_ts ON events(ts);
            CREATE TABLE IF NOT EXISTS state (key TEXT PRIMARY KEY, val TEXT);
        ''')
        self.state = {k: json.loads(v) for k, v in self.db.execute('SELECT key, val FROM state')}

    def put(self, doc, now):
        with self.lock:
            prev = self.db.execute('SELECT doc FROM latest WHERE host=?', (doc['host'],)).fetchone()
            s = json.dumps(doc, separators=(',', ':'))
            self.db.execute('INSERT OR REPLACE INTO latest VALUES (?,?,?,?)', (doc['host'], doc['ts'], now, s))
            self.db.execute('INSERT INTO samples VALUES (?,?,?)', (doc['host'], doc['ts'], s))
            self.db.commit()
            return json.loads(prev[0]) if prev else None

    def latest(self):
        with self.lock:
            return [(json.loads(d), r) for d, r in self.db.execute('SELECT doc, recv FROM latest ORDER BY host')]

    def samples(self, host, since):
        with self.lock:
            return [json.loads(d) for (d,) in self.db.execute(
                'SELECT doc FROM samples WHERE host=? AND ts>=? ORDER BY ts', (host, since))]

    def event(self, ts, host, level, key, msg):
        with self.lock:
            self.db.execute('INSERT INTO events VALUES (?,?,?,?,?)', (ts, host, level, key, msg))
            self.db.commit()

    def events(self, limit):
        with self.lock:
            return [dict(ts=t, host=h, level=l, key=k, msg=m) for t, h, l, k, m in self.db.execute(
                'SELECT ts, host, level, key, msg FROM events ORDER BY ts DESC, rowid DESC LIMIT ?', (limit,))]

    def set_state(self, key, val):
        with self.lock:
            if val is None:
                self.state.pop(key, None); self.db.execute('DELETE FROM state WHERE key=?', (key,))
            else:
                self.state[key] = val; self.db.execute('INSERT OR REPLACE INTO state VALUES (?,?)', (key, json.dumps(val)))
            self.db.commit()

    def prune(self, now):
        with self.lock:
            cut = now - KEEP_DAYS * 86400
            self.db.execute('DELETE FROM samples WHERE ts<?', (cut,))
            self.db.execute('DELETE FROM events WHERE ts<?', (cut - 23 * 86400,))   # 이벤트는 30일
            self.db.commit()


class Rules:
    """상태를 판정한다. 지속형 경보(alert)는 시작·해소를 이벤트로 남기고, 순간형(재시작·드롭 증가)은 바로 남긴다."""

    def __init__(self, store, labels=None):
        self.st = store
        self.labels = labels or {}

    def _alert(self, now, host, key, active, level, msg):
        k = f'alert:{host}:{key}'
        cur = self.st.state.get(k)
        if active and not cur:
            self.st.set_state(k, {'since': now, 'level': level, 'msg': msg})
            self.st.event(now, host, level, key, msg)
        elif active and cur and cur.get('msg') != msg:
            cur['msg'] = msg; self.st.set_state(k, cur)
        elif not active and cur:
            self.st.set_state(k, None)
            self.st.event(now, host, 'ok', key, f'해소: {cur["msg"]} ({fmt_dur(now - cur["since"])} 지속)')

    def on_push(self, doc, prev, now):
        h = doc['host']
        pu = {u['name']: u for u in (prev or {}).get('units', [])}
        seen = set()
        for u in doc.get('units', []):
            n = u['name']; seen.add(n); p = pu.get(n, {})
            self._alert(now, h, f'{n}:down', not u.get('active'), 'crit', f'{n} 정지 ({u.get("state")})')
            if p and u.get('pid') and p.get('pid') and u['pid'] != p['pid']:
                self.st.event(now, h, 'warn', f'{n}:restart',
                              f'{n} 재시작 (PID {p["pid"]}→{u["pid"]}, 버전 {p.get("version", "?")}→{u.get("version", "?")})')
            if p and u.get('drops', 0) > p.get('drops', 0) and u.get('pid') == p.get('pid'):
                self.st.event(now, h, 'warn', f'{n}:drops', f'{n} 소켓 drops +{u["drops"] - p["drops"]}')
            if p and u.get('errors_recent', 0) > p.get('errors_recent', 0) and u.get('pid') == p.get('pid'):
                self.st.event(now, h, 'warn', f'{n}:error', f'{n} 로그 ERROR +{u["errors_recent"] - p["errors_recent"]}')
            for pa in u.get('paths', []):
                key = f'{n}:path{pa["i"]}'
                bad = pa['status'] != 'RUNNING'
                tk = f'bad:{h}:{key}'
                if bad:
                    since = self.st.state.get(tk) or now
                    if not self.st.state.get(tk):
                        self.st.set_state(tk, now)
                    self._alert(now, h, key, now - since >= PATH_BAD_SEC, 'crit',
                                f'{n} path[{pa["i"]}] {pa["status"]} {fmt_dur(now - since)}째 (loss {pa["loss"]}%)')
                else:
                    self.st.set_state(tk, None)
                    self._alert(now, h, key, False, 'crit', '')
        self.relay_rules(doc, prev, now)
        for n in pu:
            if n not in seen:
                self.st.event(now, h, 'warn', f'{n}:gone', f'{n} 유닛이 목록에서 사라짐')
        hs, ps = doc.get('host_stats', {}), (prev or {}).get('host_stats', {})
        e1, e0 = hs.get('udp', {}).get('RcvbufErrors'), ps.get('udp', {}).get('RcvbufErrors')
        if e1 is not None and e0 is not None and e1 > e0:
            self.st.event(now, h, 'warn', 'udp_rcvbuf', f'UDP 수신 버퍼 넘침 +{e1 - e0} (호스트 전체)')
        self._alert(now, h, 'ntp', hs.get('ntp_sync') is False, 'warn',
                    '시계 동기 안 됨 (mud timetolerance 30초를 넘으면 터널이 조용히 멈춘다)')
        for w in hs.get('wg', []):
            age = w.get('handshake_age')
            self._alert(now, h, f'wg:{w["if"]}:{w["peer"]}', age is None or age > WG_HS_SEC, 'warn',
                        f'WireGuard {w["if"]} 피어 {w["peer"]} 핸드셰이크 '
                        + ('없음' if age is None else f'{fmt_dur(age)} 전'))

    def relay_rules(self, doc, prev, now):
        h = doc['host']
        pu = {u['name']: u for u in (prev or {}).get('units', [])}
        for u in doc.get('units', []):
            if u.get('role') != 'relay' or 'session_list' not in u:
                continue
            n, p = u['name'], pu.get(u['name'], {})
            cur = {(x['client'], x['fd']): x for x in u['session_list']}
            if p.get('pid') == u.get('pid') and 'session_list' in p:
                old = {(x['client'], x['fd']): x for x in p['session_list']}
                for k in cur.keys() - old.keys():
                    x = cur[k]
                    self.st.event(now, h, 'info', f'{n}:session', f'{n} 새 세션 {branch_name(self.labels, x)} {x["client"]} → {x["upstream"]}')
                for k in old.keys() - cur.keys():
                    x = old[k]
                    self.st.event(now, h, 'info', f'{n}:session', f'{n} 세션 종료 {branch_name(self.labels, x)} {x["client"]}')
                if u.get('probes', 0) > p.get('probes', 0):
                    top = ', '.join(f'{ip}×{c}' for ip, c in u.get('probe_top', [])[:3])
                    self.st.event(now, h, 'warn', f'{n}:probe', f'{n} 인증 실패 접속(프로브) +{u["probes"] - p["probes"]} — {top}')
                if u.get('table_full', 0) > p.get('table_full', 0):
                    self.st.event(now, h, 'crit', f'{n}:full', f'{n} 세션 테이블 가득 참 +{u["table_full"] - p["table_full"]} (LRU 축출)')
            # 지사(키) × relay 존재 감시
            present = {branch_id(x) for x in u['session_list']}
            for b in present:
                self.st.set_state(f'seen:{h}/{n}:{b}', now)
            for k, last in list(self.st.state.items()):
                pre = f'seen:{h}/{n}:'
                if not k.startswith(pre):
                    continue
                b = k[len(pre):]
                if b in present:
                    self._alert(now, h, f'{n}:branch:{b}', False, 'crit', '')
                    continue
                if now - last > BRANCH_FORGET_SEC:
                    self.st.set_state(k, None); self._alert(now, h, f'{n}:branch:{b}', False, 'crit', ''); continue
                self._alert(now, h, f'{n}:branch:{b}', now - last >= BRANCH_GONE_SEC, 'crit',
                            f'지사 {self.labels.get(b, b)} — {n} 경유 세션 없음 ({fmt_dur(now - last)}째)')

    def tick(self, now):
        rows = self.st.latest()
        for doc, recv in rows:
            age = now - recv
            self._alert(now, doc['host'], 'stale', age > STALE_SEC, 'crit', f'에이전트 보고 끊김 ({fmt_dur(age)} 전 마지막)')
        vers = {}
        for doc, _ in rows:
            for u in doc.get('units', []):
                if u.get('version'):
                    vers.setdefault(u['version'], []).append(f'{doc["host"]}/{u["name"]}')
        self._alert(now, '*', 'version_mix', len(vers) > 1, 'info',
                    '버전 혼재: ' + ' · '.join(f'{v} {len(us)}개' for v, us in sorted(vers.items())))


def branch_id(x):
    """지사 식별: 키 지문(서비스망은 PSK 가 지사다). 키가 없으면(투명 중계) 클라이언트 IP."""
    return x.get('kf') or x['client'].rsplit(':', 1)[0]


def branch_name(labels, x):
    b = branch_id(x)
    return f'{labels[b]}({b})' if b in labels else b


def fmt_dur(s):
    s = int(s)
    return f'{s}초' if s < 120 else f'{s // 60}분' if s < 7200 else f'{s // 3600}시간'


SERIES = {   # history 에서 뽑을 수 있는 계열: (설명, 단위별 추출 함수)
    'cpu': lambda u, p: u.get('cpu'), 'rss': lambda u, p: u.get('rss_mb'), 'fd': lambda u, p: u.get('fd'),
    'sessions': lambda u, p: u.get('sessions'), 'drops': lambda u, p: u.get('drops'),
    'probes': lambda u, p: u.get('probes'),
    'owd': lambda u, p: p and p.get('owd'), 'loss': lambda u, p: p and p.get('loss'),
    'tx': lambda u, p: p and p.get('tx'), 'rx': lambda u, p: p and p.get('rx'),
}


def history(store, host, unit, series, path, hours):
    now = int(time.time())
    out = []
    f = SERIES[series]
    for d in store.samples(host, now - int(hours * 3600)):
        for u in d.get('units', []):
            if u['name'] != unit:
                continue
            p = None
            if path is not None:
                p = next((x for x in u.get('paths', []) if x['i'] == path), None)
            v = f(u, p)
            if v is not None:
                out.append([d['ts'], v])
    return out


def host_history(store, host, key, hours):
    now = int(time.time())
    return [[d['ts'], d.get('host_stats', {}).get(key)] for d in store.samples(host, now - int(hours * 3600))
            if d.get('host_stats', {}).get(key) is not None]


class App:
    def __init__(self, a):
        self.st = Store(a.db)
        self.labels = {}
        if a.labels and os.path.exists(a.labels):
            for line in open(a.labels):
                f = line.split(None, 1)
                if len(f) == 2 and not f[0].startswith('#'):
                    self.labels[f[0]] = f[1].strip()
        self.rules = Rules(self.st, self.labels)
        self.tokens = {}
        if a.tokens:
            for line in open(a.tokens):
                f = line.split()
                if len(f) == 2 and not f[0].startswith('#'):
                    self.tokens[f[1]] = f[0]
        if not self.tokens:
            sys.exit('tokens 파일에 `호스트 토큰` 줄이 하나도 없다')
        with self.st.lock:   # 토큰에서 빠진 호스트는 감시 대상이 아니다 — 남은 마지막 보고와 경보를 지운다(이력 samples 는 보존)
            hosts = set(self.tokens.values())
            gone = [h for (h,) in self.st.db.execute('SELECT host FROM latest') if h not in hosts]
            for h in gone:
                self.st.db.execute('DELETE FROM latest WHERE host=?', (h,))
            self.st.db.commit()
        for h in gone:
            for k in [k for k in self.st.state if k.startswith((f'alert:{h}:', f'bad:{h}:', f'seen:{h}/'))]:
                self.st.set_state(k, None)
            print(f'mf-status: 토큰에 없는 호스트 {h} 를 목록에서 뺐다', flush=True)
        self.html = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'dashboard.html'), 'rb').read()

    def host_for(self, auth):
        if not auth.startswith('Bearer '):
            return None
        tok = auth[7:].strip()
        for t, h in self.tokens.items():
            if hmac.compare_digest(t, tok):
                return h
        return None

    def push(self, doc, host):
        now = int(time.time())
        if doc.get('host') != host:
            return 403, {'error': f'토큰은 {host} 의 것이다 (문서 host={doc.get("host")})'}
        if not isinstance(doc.get('units'), list) or not isinstance(doc.get('ts'), int):
            return 400, {'error': '형식 오류'}
        skew = doc['ts'] - now
        prev = self.st.put(doc, now)
        self.rules.on_push(doc, prev, now)
        self.rules._alert(now, host, 'clock', abs(skew) > 10, 'warn', f'에이전트 시계가 중앙과 {skew:+d}초 차이')
        return 200, {'ok': True}

    def status(self):
        now = int(time.time())
        hosts = []
        for doc, recv in self.st.latest():
            doc['age'] = now - recv
            hosts.append(doc)
        alerts = [dict(key=k.split(':', 2)[2], host=k.split(':', 2)[1], **v)
                  for k, v in self.st.state.items() if k.startswith('alert:')]
        alerts.sort(key=lambda x: ({'crit': 0, 'warn': 1, 'info': 2}.get(x['level'], 3), x['since']))
        seen = []
        for k, v in self.st.state.items():
            if k.startswith('seen:'):
                relay, b = k[5:].split(':', 1)
                seen.append({'relay': relay, 'branch': b, 'last': v})
        return {'now': now, 'hosts': hosts, 'alerts': alerts, 'labels': self.labels, 'branch_seen': seen}

    def loop(self):
        n = 0
        while True:
            try:
                self.rules.tick(int(time.time()))
                n += 1
                if n % 360 == 0:
                    self.st.prune(int(time.time()))
            except Exception as e:
                print(f'규칙 오류: {e}', file=sys.stderr, flush=True)
            time.sleep(10)


def handler(app):
    class H(BaseHTTPRequestHandler):
        server_version = 'mf-status'

        def log_message(self, fmt, *args):
            pass

        def send(self, code, body, ctype='application/json; charset=utf-8'):
            if not isinstance(body, bytes):
                body = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(code)
            self.send_header('Content-Type', ctype)
            self.send_header('Content-Length', str(len(body)))
            self.send_header('Cache-Control', 'no-store')
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            u = urlparse(self.path); q = {k: v[0] for k, v in parse_qs(u.query).items()}
            try:
                if u.path == '/':
                    return self.send(200, app.html, 'text/html; charset=utf-8')
                if u.path == '/api/status':
                    return self.send(200, app.status())
                if u.path == '/api/events':
                    return self.send(200, app.st.events(min(int(q.get('limit', 200)), 2000)))
                if u.path == '/api/history':
                    hours = min(float(q.get('hours', 6)), KEEP_DAYS * 24)
                    if q.get('series') in ('rx_mbps', 'tx_mbps'):
                        return self.send(200, host_history(app.st, q['host'], q['series'], hours))
                    if q.get('series') not in SERIES:
                        return self.send(400, {'error': 'series'})
                    path = int(q['path']) if q.get('path', '') != '' else None
                    return self.send(200, history(app.st, q['host'], q['unit'], q['series'], path, hours))
            except (KeyError, ValueError):
                return self.send(400, {'error': '인자 오류'})
            self.send(404, {'error': 'not found'})

        def do_POST(self):
            if urlparse(self.path).path != '/api/push':
                return self.send(404, {'error': 'not found'})
            host = app.host_for(self.headers.get('Authorization', ''))
            if not host:
                return self.send(401, {'error': '토큰'})
            n = int(self.headers.get('Content-Length', 0) or 0)
            if n <= 0 or n > MAX_BODY:
                return self.send(413, {'error': '크기'})
            try:
                doc = json.loads(self.rfile.read(n))
            except ValueError:
                return self.send(400, {'error': 'JSON'})
            code, body = app.push(doc, host)
            self.send(code, body)
    return H


def main():
    ap = argparse.ArgumentParser(description='multi-fec 상태 중앙 서버 (테스트망 전용)')
    ap.add_argument('--listen', default='127.0.0.1:8780')
    ap.add_argument('--db', default='mf-status.db')
    ap.add_argument('--tokens', required=True, help='`호스트 토큰` 줄 파일 (권한 600 권장)')
    ap.add_argument('--labels', default='/etc/mf-status/labels', help='`kf:xxxxxxxx 지사이름` 줄 파일 (없으면 지문만 표시)')
    a = ap.parse_args()
    app = App(a)
    host, port = a.listen.rsplit(':', 1)
    srv = ThreadingHTTPServer((host, int(port)), handler(app))
    threading.Thread(target=app.loop, daemon=True).start()
    print(f'mf-status: http://{a.listen}/  (호스트 {len(app.tokens)}개 등록)', flush=True)
    srv.serve_forever()


if __name__ == '__main__':
    main()
