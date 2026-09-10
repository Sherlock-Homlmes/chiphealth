/**
 * Verifies every Workers AI model id in the config actually exists and returns
 * the shape the code expects. A wrong model id fails at request time in
 * production, which is the worst place to find out.
 *
 * Uses the REST API with CLOUDFLARE_API_TOKEN so it can run without a deploy.
 */
import { readFileSync } from 'node:fs';

const vars = Object.fromEntries(
  readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8')
    .split('\n')
    .filter((l) => l.includes('=') && !l.trimStart().startsWith('#'))
    .map((l) => [l.slice(0, l.indexOf('=')).trim(), l.slice(l.indexOf('=') + 1).trim()]),
);

const token = process.env.CLOUDFLARE_API_TOKEN;
const account = process.env.CLOUDFLARE_ACCOUNT_ID ?? vars.R2_ACCOUNT_ID;
if (!token || !account) {
  console.error('need CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID');
  process.exit(1);
}

const run = async (model, body) => {
  const res = await fetch(
    `https://api.cloudflare.com/client/v4/accounts/${account}/ai/run/${model}`,
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    },
  );
  return { status: res.status, json: await res.json().catch(() => null) };
};

let failures = 0;
const check = (name, ok, detail = '') => {
  console.log(`${ok ? '  ok ' : 'FAIL'}  ${name}${detail ? ` — ${detail}` : ''}`);
  if (!ok) failures++;
};

const EMBEDDING = vars.AI_EMBEDDING_MODEL ?? '@cf/baai/bge-m3';
const CHAT = vars.AI_CHAT_MODEL ?? '@cf/meta/llama-3.3-70b-instruct-fp8-fast';
const DIMS = Number(vars.AI_EMBEDDING_DIMENSIONS ?? 1024);

console.log(`account=${account.slice(0, 6)}…\n`);

// 1. Embeddings must exist AND match the Vectorize index dimensions, or every
//    upsert fails after the index is already created.
const embed = await run(EMBEDDING, { text: ['cơm tấm sườn nướng', 'com tam suon nuong'] });
const vectors = embed.json?.result?.data;
check(`embedding model ${EMBEDDING} responds`, embed.status === 200 && Array.isArray(vectors),
  `HTTP ${embed.status}${embed.json?.errors?.[0]?.message ? ` ${embed.json.errors[0].message}` : ''}`);

if (Array.isArray(vectors) && vectors[0]) {
  check(`embedding dimensions == AI_EMBEDDING_DIMENSIONS (${DIMS})`,
    vectors[0].length === DIMS, `model returned ${vectors[0].length}`);

  // Diacritic-stripped Vietnamese should still land near the accented form —
  // this is the half of retrieval that BM25 cannot do.
  const dot = vectors[0].reduce((sum, v, i) => sum + v * vectors[1][i], 0);
  const norm = (v) => Math.sqrt(v.reduce((s, x) => s + x * x, 0));
  const cosine = dot / (norm(vectors[0]) * norm(vectors[1]));
  check('“com tam” embeds close to “cơm tấm”', cosine > 0.7, `cosine ${cosine.toFixed(3)}`);
}

// 2. Chat model must exist and be able to answer in Vietnamese.
const chat = await run(CHAT, {
  messages: [
    { role: 'system', content: 'Trả lời bằng tiếng Việt, đúng một câu ngắn.' },
    { role: 'user', content: 'Một bát phở bò khoảng bao nhiêu calo?' },
  ],
  max_tokens: 80,
});
const reply = chat.json?.result?.response;
check(`chat model ${CHAT} responds`, chat.status === 200 && typeof reply === 'string' && reply.length > 0,
  `HTTP ${chat.status}${chat.json?.errors?.[0]?.message ? ` ${chat.json.errors[0].message}` : ''}`);
if (reply) console.log(`        ↳ ${reply.trim().slice(0, 120)}`);

// 3. Strict-JSON behaviour is what the meal analyser depends on.
const json = await run(CHAT, {
  messages: [
    { role: 'system', content: 'Trả về DUY NHẤT JSON, không giải thích.' },
    { role: 'user', content: 'Ước lượng dinh dưỡng 100g cơm trắng. Keys: caloriesKcal, proteinG, carbsG, fatG.' },
  ],
  max_tokens: 200,
  temperature: 0.2,
});
const text = json.json?.result?.response ?? '';
const start = text.indexOf('{');
const end = text.lastIndexOf('}');
let parsed = null;
if (start !== -1 && end > start) {
  try { parsed = JSON.parse(text.slice(start, end + 1)); } catch { /* reported below */ }
}
check('chat model returns parseable JSON for nutrition',
  parsed !== null && typeof parsed.caloriesKcal === 'number',
  parsed ? `kcal=${parsed.caloriesKcal}` : `raw: ${text.slice(0, 80)}`);

console.log(`\n${failures === 0 ? 'Workers AI OK' : `${failures} failed`}`);
process.exit(failures > 0 ? 1 : 0);
