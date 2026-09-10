# ChipHealth

Comprehensive personal health tracking — nutrition, training, sleep, body metrics, and an
AI coach — with a Locket-style photo widget on top.

```
chiphealth/
├── db_design.dbml     # database design of record (44 tables, Cloudflare D1 / SQLite)
├── api_design.md      # API contract — read this before touching any client
├── backend/           # Hono on Cloudflare Workers: D1 + R2 + Workers AI + Vectorize
├── admin/             # Vue 3 admin panel (food DB, barcode queue, RAG corpus, catalogs)
└── app/               # Flutter mobile app (retro styling, shadcn_ui)
```

## Architecture at a glance

| Concern | Choice | Why |
|---|---|---|
| DB | Cloudflare D1 (SQLite) | Same platform as the Worker; no connection pooling problem |
| Ids | UUIDv7 `TEXT` | Time-sortable, so `ORDER BY id DESC` is newest-first on the PK index, and clients can mint ids offline |
| Time | epoch **milliseconds**, plus a `local_date` string per log row | "How many calories today" is a local-calendar question, not a UTC one |
| GPS / HR samples | R2 object + one `workout_streams` row | 1 h at 1 Hz is ~7k rows per workout — far too many for D1 |
| Media | R2, registered in `media_assets` | One table to sweep orphans; sleep audio clips are kept forever by design |
| Food search | FTS5 BM25 + Vectorize ANN, fused with RRF | Vietnamese dish names need lexical matching *and* semantics; RRF needs no score normalisation |
| AI | Workers AI, model ids in env | Swap a model by changing one variable — see `backend/.dev.vars.example` |
| Auth | Google OAuth only | One flow for the app and the admin panel |

## Design decisions worth knowing before you edit anything

- **AI guesses are never overwritten.** A meal photo produces `meal_items` rows plus one
  immutable `meal_ai_analyses` row. When the user corrects an item, the original prediction
  is preserved in `meal_items.ai_predicted_json`. Every correction is therefore a
  (prediction, ground truth) pair for later fine-tuning.
- **The food database is per-person on top of a global one.** The same dish differs between
  households, so corrections are learned into the caller's `user_foods` and outrank the
  global `foods` row on the next match.
- **Barcodes are admin-entered only.** A user scanning an unknown code gets
  "chưa có dữ liệu" and the code lands in `barcode_scan_misses`, aggregated by barcode so
  `scan_count` tells the admin what to enter next.
- **HR zones are versioned.** Recalculating inserts a new set with a fresh `effective_from`;
  old workouts keep the zones they were originally scored with.
- **Sleep debt** uses a fixed personal target accumulated over a rolling 14-day window.
- **Wearables are optional.** With Apple Health / Health Connect connected the data is read
  on-device (no server-side OAuth token exists); without one, sleep comes from the phone mic
  and energy is estimated from MET × duration, flagged with `is_estimated`.

## Verification status

| Area | Checked with | Result |
|---|---|---|
| Backend types | `npm run typecheck` | 0 errors |
| Backend logic | `npm test` (51 pure-function tests) | pass |
| Schema | migrations + seed on a fresh SQLite, FTS5 diacritic match | pass |
| Worker bundle | `wrangler deploy --dry-run` | 631 KB |
| API | live `wrangler dev` + curl over every domain | pass |
| Admin panel | `vue-tsc`, `vite build`, headless Chrome against the real API | pass |
| Mobile app | `flutter analyze` + `flutter test` (37 tests) in the pinned image | 0 issues, all pass |
| Mobile app (web) | built and driven in headless Chrome against the live API | renders seeded data |
| R2 | `npm run r2:smoke` — PUT/GET/HEAD/LIST/DELETE + public URL | pass |
| Workers AI | `npm run ai:smoke` | pass — embeddings 1024 dims, chat returns parseable JSON |
| Vectorize | `chiphealth-food` created, 1024 dims, cosine | pass |
| Meal photo analysis | live upload → components → totals | pass |
| Spoken meal logging | `POST /v1/meals/:id/voice` | pass |

## Getting started

```bash
# backend  ->  http://127.0.0.1:8787
cd backend
cp .dev.vars.example .dev.vars        # fill in GOOGLE_CLIENT_IDS + JWT_SECRET
npm install
npx wrangler d1 create chiphealth      # put the id into wrangler.toml
npm run vectorize:create               # 1024 dims, cosine — must match AI_EMBEDDING_MODEL
npm run db:migrate:local && npm run db:seed:local
npm run dev

# admin panel  ->  http://127.0.0.1:5174
cd ../admin && npm install && npx vite --port 5174

# mobile app — no local SDK needed, the pinned image is the toolchain
cd ../app
docker volume create chiphealth-pubcache
docker run --rm -v "$PWD":/app -v chiphealth-pubcache:/pubcache \
  -e PUB_CACHE=/pubcache -w /app ghcr.io/cirruslabs/flutter:stable \
  bash -lc "flutter pub get && flutter analyze && flutter test"
```

### Running the mobile app in a browser  ->  http://127.0.0.1:5180

The fastest way to look at the app without a device. Camera, GPS, microphone and
the home-screen widget do not work on web, but every screen, the API wiring and
the retro theme do.

```bash
cd app
docker run --rm -v "$PWD":/app -v chiphealth-pubcache:/pubcache \
  -e PUB_CACHE=/pubcache -w /app ghcr.io/cirruslabs/flutter:stable \
  bash -lc "flutter build web --debug --no-wasm-dry-run --dart-define=API_BASE_URL="
node tools/serve-web.mjs 5180
```

`tools/serve-web.mjs` serves `build/web` **and** proxies `/v1` to the Worker, so
the app talks to the API on its own origin: no CORS entry, no hardcoded host. It
also vends a dev session at `/__dev/session`, which is how the app signs in
without a Google OAuth client — refresh tokens rotate on first use, so each
browser needs its own. That endpoint exists only in this dev proxy; the Worker
knows nothing about it. **Never expose that port publicly.**

### Opening the admin panel without a Google OAuth client

Google is the only sign-in method, so local dev needs either a real client id or a
seeded session:

```bash
cd backend
npm run dev:session   # prints a console snippet that logs the admin panel in
npm run dev:demo      # fills the account with a fortnight of realistic data
```

`dev:session` creates an admin user plus a refresh token in the **local** D1 file.
Nothing in the Worker changes — the token is inserted exactly the way
`/v1/auth/google` would.

`dev:demo` goes through the HTTP API rather than writing rows directly, so the
nightly rollups, the sleep-debt window and PR detection all run for real: it
uploads three synthetic GPS streams and the server derives the splits, time-in-zone
and personal records from them.

### Smoke tests against real Cloudflare services

```bash
cd backend
npm run r2:smoke    # PUT/GET/HEAD/LIST/DELETE + the public URL
npm run ai:smoke    # every model id in the config, plus embedding dimensions
```

`ai:smoke` needs a token with **Workers AI: Read**; creating the Vectorize index needs
**Vectorize: Edit**. Llama and Gemma models also require a one-time licence acceptance
per account — running one before that returns `5016` telling you to POST the prompt
`agree` to that model once.

### Choosing the vision model

`AI_VISION_MODEL` decides how meal photos are read, and the models differ by more than
accuracy: a reasoning model spends ~30 s thinking before it answers. The measured
trade-off, and the models that are not available on the Workers Free plan, are written
down in `backend/.dev.vars.example` next to the setting itself.
