#!/usr/bin/env python3
"""Modest multi-source HTTPS load generator (stdlib only) for zero-downtime tests.
Each worker binds its own source IP (so the per-IP rate limit is respected), opens a NEW TLS connection per request
(stricter than keep-alive: a refused/reset connection during a cutover is counted) and paces itself to --rps.
  loadgen.py --host next.ship.test --ip 198.51.100.20 --path /api/health --ca ca.crt --sources 198.51.100.60-69 \
             --rps 20 --seconds 120 --out /tmp/load.log
Log lines: <unix_ts> <source> <status|ERR:reason> <latency_ms> <version>"""
import argparse, http.client, json, re, ssl, threading, time

ap = argparse.ArgumentParser()
for a in ("--host", "--ip", "--path", "--ca", "--sources", "--out"): ap.add_argument(a, required=True)
ap.add_argument("--port", type=int, default=443); ap.add_argument("--rps", type=float, default=20)
ap.add_argument("--seconds", type=float, default=120)
o = ap.parse_args()
base, rng = o.sources.rsplit(".", 1); lo, hi = map(int, rng.split("-"))
sources = ["%s.%d" % (base, i) for i in range(lo, hi + 1)]
ctx = ssl.create_default_context(cafile=o.ca)
lock = threading.Lock(); out = open(o.out, "w"); stop = time.time() + o.seconds
VER = re.compile(r'"version":"([^"]*)"|id="v">([^<]*)')

def worker(src):
    period = 1.0 / o.rps; nxt = time.time()
    while time.time() < stop:
        t0 = time.time(); ver = "-"
        try:
            c = http.client.HTTPSConnection(o.ip, o.port, timeout=5, context=ctx, source_address=(src, 0))
            c.request("GET", o.path, headers={"Host": o.host, "User-Agent": "ship-loadgen/1", "Connection": "close"})
            r = c.getresponse(); body = r.read(4096).decode("utf-8", "replace"); st = str(r.status)
            m = VER.search(body); ver = (m.group(1) or m.group(2)) if m else "-"
            c.close()
        except Exception as e:
            st = "ERR:" + type(e).__name__
        with lock:
            out.write("%.3f %s %s %d %s\n" % (t0, src, st, (time.time() - t0) * 1000, ver)); out.flush()
        nxt += period; time.sleep(max(0, nxt - time.time()))

# HTTPSConnection to an IP must still send SNI = host: patch connect to wrap with server_hostname
def _connect(self):
    http.client.HTTPConnection.connect(self)
    self.sock = self._context.wrap_socket(self.sock, server_hostname=self._sni)
http.client.HTTPSConnection.connect = _connect
_init = http.client.HTTPSConnection.__init__
def _ninit(self, *a, **k):
    _init(self, *a, **k); self._sni = o.host
http.client.HTTPSConnection.__init__ = _ninit

ts = [threading.Thread(target=worker, args=(s,), daemon=True) for s in sources]
[t.start() for t in ts]; [t.join() for t in ts]
out.close()
