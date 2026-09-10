/**
 * Serves `build/web` and proxies the API on the same origin, so the web build
 * needs no CORS allowance and no hardcoded host: the app resolves its API base
 * from `Uri.base.origin` (see lib/core/config/env.dart).
 *
 *   node tools/serve-web.mjs [port] [apiTarget]
 */
import { createServer, request } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { createReadStream, existsSync, readFileSync, statSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { extname, join, normalize } from 'node:path';

const PORT = Number(process.argv[2] ?? 5175);
const API = new URL(process.argv[3] ?? 'http://127.0.0.1:8787');
const ROOT = new URL('../build/web/', import.meta.url).pathname;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.wasm': 'application/wasm',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.ttf': 'font/ttf',
  '.otf': 'font/otf',
  '.woff2': 'font/woff2',
  '.map': 'application/json; charset=utf-8',
};

const isApi = (url) => url.startsWith('/v1/') || url === '/health';

/**
 * Dev-only session vending, so the web build can be opened in any browser
 * without a Google OAuth client. It shells out to the same script a human would
 * run; nothing in the Worker knows this exists, and it lives here rather than in
 * the app so no build can accidentally ship it.
 *
 * A fresh token per request matters: refresh tokens rotate on first use, so one
 * baked-in token only ever logs in one browser once.
 */
function devSession(res) {
  try {
    const out = execFileSync('node', ['scripts/dev-session.mjs'], {
      cwd: new URL('../../backend/', import.meta.url).pathname,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
    });
    const token = out.match(/refreshToken', '([^']+)'/)?.[1];
    if (!token) throw new Error('dev-session.mjs printed no token');
    res.writeHead(200, { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify({ refreshToken: token }));
  } catch (err) {
    res.writeHead(500, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: { code: 'DEV_SESSION_FAILED', message: String(err) } }));
  }
}

function proxy(req, res) {
  const upstream = request(
    {
      hostname: API.hostname,
      port: API.port,
      path: req.url,
      method: req.method,
      headers: { ...req.headers, host: API.host },
    },
    (upstreamRes) => {
      res.writeHead(upstreamRes.statusCode ?? 502, upstreamRes.headers);
      upstreamRes.pipe(res);
    },
  );
  upstream.on('error', (err) => {
    res.writeHead(502, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({
      error: { code: 'UPSTREAM_DOWN', message: `Cannot reach ${API.origin}: ${err.message}` },
    }));
  });
  req.pipe(upstream);
}

function serveStatic(req, res) {
  // Everything that is not a real file is the SPA entry point, so deep links work.
  const raw = decodeURIComponent((req.url ?? '/').split('?')[0]);
  const safe = normalize(raw).replace(/^(\.\.[/\\])+/, '');
  let file = join(ROOT, safe === '/' ? 'index.html' : safe);

  try {
    if (statSync(file).isDirectory()) file = join(file, 'index.html');
  } catch {
    file = join(ROOT, 'index.html');
  }

  try {
    statSync(file);
  } catch {
    res.writeHead(404).end('not found');
    return;
  }

  res.writeHead(200, {
    'Content-Type': MIME[extname(file)] ?? 'application/octet-stream',
    'Cache-Control': 'no-store',
  });
  createReadStream(file).pipe(res);
}

/**
 * `flutter_secure_storage` on web derives its AES-GCM key through `crypto.subtle`,
 * which the browser only exposes in a secure context. Over plain HTTP on anything
 * but localhost the app therefore mints a dev session and then throws trying to
 * store it, so every call stays unauthenticated. Serving TLS — even with a
 * self-signed certificate the developer clicks past once — makes the origin
 * secure and the token persists.
 */
const CERT = new URL('./certs/dev-cert.pem', import.meta.url).pathname;
const KEY = new URL('./certs/dev-key.pem', import.meta.url).pathname;
const tls = existsSync(CERT) && existsSync(KEY);

const handler = (req, res) => {
  const url = req.url ?? '';
  if (url === '/__dev/session') return devSession(res);
  return isApi(url) ? proxy(req, res) : serveStatic(req, res);
};

const server = tls
  ? createHttpsServer({ cert: readFileSync(CERT), key: readFileSync(KEY) }, handler)
  : createServer(handler);

server.listen(PORT, '0.0.0.0', () => {
  const scheme = tls ? 'https' : 'http';
  console.log(`ChipHealth web  ${scheme}://0.0.0.0:${PORT}   (API proxied to ${API.origin})`);
  if (!tls) {
    console.log('no tools/certs/dev-{cert,key}.pem — serving plain HTTP, so');
    console.log('flutter_secure_storage only works via localhost/127.0.0.1');
  }
  console.log('dev sessions vended at /__dev/session — never expose this port publicly');
});
