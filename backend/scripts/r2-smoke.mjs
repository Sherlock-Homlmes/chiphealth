/**
 * End-to-end check against the real R2 bucket over the S3-compatible API:
 * PUT an object, GET it back, HEAD it, LIST the prefix, DELETE it.
 *
 * The Worker itself uses the R2 *binding* (no keys), so this only proves the
 * bucket, credentials and public URL are right — which is what breaks first.
 *
 * Reads R2_* from .dev.vars. Never prints a secret.
 */
import { createHash, createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';

const vars = Object.fromEntries(
  readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8')
    .split('\n')
    .filter((line) => line.includes('=') && !line.trimStart().startsWith('#'))
    .map((line) => {
      const idx = line.indexOf('=');
      return [line.slice(0, idx).trim(), line.slice(idx + 1).trim()];
    }),
);

const ACCOUNT = vars.R2_ACCOUNT_ID;
const KEY = vars.R2_ACCESS_KEY_ID;
const SECRET = vars.R2_SECRET_ACCESS_KEY;
const BUCKET = vars.R2_BUCKET_NAME;
const PUBLIC_URL = vars.R2_PUBLIC_URL ?? vars.R2_PUBLIC_BASE_URL;

for (const [name, value] of Object.entries({ ACCOUNT, KEY, SECRET, BUCKET })) {
  if (!value) {
    console.error(`missing R2_${name} in .dev.vars`);
    process.exit(1);
  }
}

const HOST = `${ACCOUNT}.r2.cloudflarestorage.com`;
const REGION = 'auto';
const SERVICE = 's3';

const sha256 = (data) => createHash('sha256').update(data).digest('hex');
const hmac = (key, data) => createHmac('sha256', key).update(data).digest();

/** AWS SigV4 for a single request. R2 requires the payload hash header. */
function sign({ method, path, query = '', body = '' }) {
  const now = new Date();
  const amzDate = now.toISOString().replace(/[:-]|\.\d{3}/g, '');
  const dateStamp = amzDate.slice(0, 8);
  const payloadHash = sha256(body);

  const canonicalHeaders =
    `host:${HOST}\n` +
    `x-amz-content-sha256:${payloadHash}\n` +
    `x-amz-date:${amzDate}\n`;
  const signedHeaders = 'host;x-amz-content-sha256;x-amz-date';

  const canonicalRequest = [
    method, path, query, canonicalHeaders, signedHeaders, payloadHash,
  ].join('\n');

  const scope = `${dateStamp}/${REGION}/${SERVICE}/aws4_request`;
  const stringToSign = [
    'AWS4-HMAC-SHA256', amzDate, scope, sha256(canonicalRequest),
  ].join('\n');

  const signingKey = ['aws4_request'].reduce(
    (key, part) => hmac(key, part),
    hmac(hmac(hmac(`AWS4${SECRET}`, dateStamp), REGION), SERVICE),
  );
  const signature = createHmac('sha256', signingKey).update(stringToSign).digest('hex');

  return {
    Authorization:
      `AWS4-HMAC-SHA256 Credential=${KEY}/${scope}, ` +
      `SignedHeaders=${signedHeaders}, Signature=${signature}`,
    'x-amz-content-sha256': payloadHash,
    'x-amz-date': amzDate,
    host: HOST,
  };
}

async function r2(method, key, { body = '', query = '' } = {}) {
  const path = key ? `/${BUCKET}/${key}` : `/${BUCKET}`;
  // SigV4 canonicalises the query string by sorting parameters; sending them in
  // any other order signs a different request and R2 answers 403.
  const canonicalQuery = query
    ? query.split('&').sort().join('&')
    : '';
  const headers = sign({ method, path, query: canonicalQuery, body });
  const url = `https://${HOST}${path}${canonicalQuery ? `?${canonicalQuery}` : ''}`;
  const res = await fetch(url, {
    method,
    headers,
    body: method === 'PUT' ? body : undefined,
  });
  return { status: res.status, text: await res.text() };
}

const testKey = `smoke/${Date.now()}-chiphealth.txt`;
const payload = `chiphealth r2 smoke ${new Date().toISOString()}`;
let failures = 0;

const check = (name, ok, detail = '') => {
  console.log(`${ok ? '  ok ' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures++;
};

console.log(`bucket=${BUCKET} account=${ACCOUNT.slice(0, 6)}…\n`);

const put = await r2('PUT', testKey, { body: payload });
check('PUT object', put.status === 200, `HTTP ${put.status}`);

const get = await r2('GET', testKey);
check('GET returns the same bytes', get.status === 200 && get.text === payload,
  `HTTP ${get.status}`);

const head = await r2('HEAD', testKey);
check('HEAD object', head.status === 200, `HTTP ${head.status}`);

const list = await r2('GET', '', { query: 'list-type=2&prefix=smoke%2F&max-keys=5' });
check('LIST prefix', list.status === 200 && list.text.includes(testKey), `HTTP ${list.status}`);

if (PUBLIC_URL) {
  const publicRes = await fetch(`${PUBLIC_URL.replace(/\/+$/, '')}/${testKey}`);
  check('public URL serves the object', publicRes.ok,
    `HTTP ${publicRes.status} — a 401/404 here just means the bucket is private`);
}

const del = await r2('DELETE', testKey);
check('DELETE object', del.status === 204 || del.status === 200, `HTTP ${del.status}`);

const gone = await r2('GET', testKey);
check('object is gone after delete', gone.status === 404, `HTTP ${gone.status}`);

console.log(`\n${failures === 0 ? 'R2 OK' : `${failures} failed`}`);
process.exit(failures > 0 ? 1 : 0);
