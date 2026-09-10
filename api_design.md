# ChipHealth — API design (v1)

Backend: **Hono on Cloudflare Workers**. DB: **D1**. Storage: **R2**. Models: **Workers AI**.
Vector index: **Vectorize**. Schema of record: `db_design.dbml` + `backend/src/db/schema/*`.

---

## 0. Conventions

| Topic | Rule |
|---|---|
| Base path | `/v1` |
| Auth | `Authorization: Bearer <access_jwt>` (HS256, 1h). Refresh via opaque token. |
| IDs | UUIDv7 strings. Clients MAY generate ids for offline-created rows (workouts, meals, sleep). |
| Time | All timestamps are epoch **milliseconds** (integer, UTC). Local days are `YYYY-MM-DD` strings. |
| Units | Request/response bodies are always metric. `unit_system` only changes rendering in the app. |
| Casing | JSON is `camelCase`; DB columns are `snake_case`. Mapping happens in the drizzle layer. |
| Errors | `{ "error": { "code": "SNAKE_CASE", "message": "human text", "details": {...} } }` |
| Validation | zod at every route boundary; failures → `400 VALIDATION_ERROR` with `details.issues`. |
| Pagination | Cursor-based: `?limit=50&cursor=<opaque>`; response `{ items: [...], nextCursor: string | null }`. Cursor = last row id (UUIDv7 sorts chronologically). |
| Idempotency | Writes that a client may retry offline accept a client-supplied `id`; re-POST with the same id is an upsert, not a duplicate. |
| CORS | Admin origin only (`ADMIN_ORIGIN`), credentials off (bearer tokens). Mobile is not a browser. |

### Standard error codes
`VALIDATION_ERROR` `UNAUTHENTICATED` `FORBIDDEN` `NOT_FOUND` `CONFLICT` `RATE_LIMITED`
`UPSTREAM_AI_ERROR` `UPLOAD_TOO_LARGE` `INTERNAL`

---

## 1. Auth

Google OAuth is the only sign-in method, for both the mobile app and the admin panel.
The client obtains a Google **id_token**; the Worker verifies it against Google's JWKS
(`https://www.googleapis.com/oauth2/v3/certs`), checks `aud ∈ GOOGLE_CLIENT_IDS`,
`iss ∈ {accounts.google.com, https://accounts.google.com}`, and `exp`.

| Method | Path | Body | Returns |
|---|---|---|---|
| POST | `/v1/auth/google` | `{ idToken, deviceName?, platform?, appVersion? }` | `{ accessToken, refreshToken, expiresAt, user }` |
| POST | `/v1/auth/refresh` | `{ refreshToken }` | `{ accessToken, refreshToken, expiresAt }` (rotates the refresh token) |
| POST | `/v1/auth/logout` | `{ refreshToken }` | `204` |
| DELETE | `/v1/auth/sessions` | — | revokes every session of the caller |

- First login creates `users` + `user_profiles`; email in `BOOTSTRAP_ADMIN_EMAILS` ⇒ `role='admin'`.
- Refresh tokens: 32 random bytes, base64url; only `sha256(token)` is stored. Rotation revokes the old row.
- `403 FORBIDDEN` from any `/v1/admin/*` route when `role != 'admin'`.

---

## 2. Profile & personalization

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/me` | user + profile + latest body metrics + active goals + conditions + wearable state |
| PATCH | `/v1/me` | `displayName, locale, unitSystem, timezone` |
| GET/PUT | `/v1/me/profile` | dob, sex, activityLevel, maxHeartRateOverride, restingHeartRate, targetSleepMinutes, bedtime/waketime |
| GET/POST | `/v1/me/conditions` · PATCH/DELETE `/v1/me/conditions/:id` | chronic conditions, free text |
| GET/POST | `/v1/me/body-metrics` | `?from=&to=` time series; POST accepts weight/height/bodyFat/… |
| GET | `/v1/me/body-metrics/latest` | current weight/height |
| GET/POST | `/v1/me/goals` · PATCH/DELETE `/v1/me/goals/:id` | multiple parallel goals; `startValue` snapshotted server-side on create |
| GET/PUT | `/v1/me/sports` | selected `activityTypeId[]` + skill level |
| GET | `/v1/me/tdee` | `{ bmrKcal, tdeeKcal, formula: "mifflin_st_jeor", inputs: {...} }` |
| DELETE | `/v1/me` | soft delete + session revoke |

**BMR (Mifflin-St Jeor)** — `10*kg + 6.25*cm − 5*age + (male ? 5 : −161)`.
**TDEE** = BMR × activity multiplier (1.2 / 1.375 / 1.55 / 1.725 / 1.9) + that day's workout calories.

---

## 3. Catalogs (public, cached)

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/catalog/activity-types` | `?locale=vi` — names resolved from `translations`, `Cache-Control: public, max-age=3600` |
| GET | `/v1/catalog/exercises` | strength-exercise catalog |

---

## 4. Media

Direct-to-R2 upload. The row is created first as an orphan and adopted when referenced.

| Method | Path | Notes |
|---|---|---|
| POST | `/v1/media/upload-url` | `{ kind, mimeType, byteSize }` → `{ assetId, uploadUrl, expiresAt }`; enforces per-kind size caps |
| POST | `/v1/media/:id/complete` | client confirms upload; server HEADs the object and fills size/dimensions |
| GET | `/v1/media/:id` | 302 to the R2 public URL, or a signed URL for private kinds |
| DELETE | `/v1/media/:id` | owner only; deletes the R2 object too |

Cron `orphan-sweeper` deletes `is_orphan = 1 AND created_at < now - ORPHAN_ASSET_TTL_HOURS`.
Sleep audio clips are **never** auto-expired.

---

## 5. Nutrition

### 5.1 Logging a meal from a photo
```
POST /v1/meals                       # create the log (id may be client-generated)
  { id?, mealType, photoAssetId?, loggedAt, localDate, note? }
POST /v1/meals/:id/analyze           # kick off AI analysis of the photo
  -> 202 { analysisId, status: "running" }
GET  /v1/meals/:id                   # poll: log + items + analysis status
```
`analyze` is synchronous-with-timeout: it returns 202 immediately and finishes in
`ctx.waitUntil`, so a slow model never blocks the request. A run still
`running`/`pending` after **3 minutes** is reported by `GET /v1/meals/:id` and the
meal lists as `failed` with `timedOut: true` (the row is only folded on read —
the 15-minute cron persists the verdict, and the app also stops waiting on its
own clock). The client then offers retry, which POSTs `/analyze` again — a new
immutable row, since attempts are never rewritten. A late model answer for a
superseded run is discarded without touching `meal_items`.

**Analysis pipeline** (`services/mealAnalysis.ts`)
1. Vision model (`AI_VISION_MODEL`) returns strict JSON: a list of components with a name,
   an estimated portion, and a confidence.
2. For each component, resolve nutrition through `services/foodSearch.ts`:
   1. barcode exact hit (only when the client sent one)
   2. **BM25** — `foods_fts` + `food_kb_fts` (`SEARCH_BM25_TOP_K`)
   3. **Vector** — Vectorize ANN over the same corpus (`SEARCH_VECTOR_TOP_K`)
   4. **RRF fusion** — `score = Σ 1/(SEARCH_RRF_K + rank)`, keep `SEARCH_FINAL_TOP_K`
      (no cross-encoder rerank in v1; `RERANK_ENABLED=false`)
   5. the caller's `user_foods` outrank a global `foods` row with the same name
   6. web-search grounding, then a pure model estimate as the last resort
3. Persist: one `meal_items` row per component (each carries its own protein / carbs / fat /
   sugar / sodium / cholesterol), plus one immutable `meal_ai_analyses` row holding the raw
   model output and the retrieval trace.
4. Recompute `meal_logs.total_*` and upsert `daily_nutrition_summaries`.

### 5.2 Corrections (fine-tuning corpus)
```
PATCH /v1/meals/:id                  # dish name, meal type, time, note
  { mealType?, dishName?, note?, loggedAt? }
PATCH /v1/meals/:id/items/:itemId    # user fixes a value
POST  /v1/meals/:id/items            # user adds a missed component
DELETE/v1/meals/:id/items/:itemId
POST  /v1/meals/:id/feedback         # thumb on the analysis
  { vote: "up" | "down" | null }     -> { userFeedback }
```
`PATCH /v1/meals/:id` re-derives `local_date` from `loggedAt`, so moving a meal in
time re-sums both the day it left and the day it landed on. `feedback` writes the
thumb onto the latest `meal_ai_analyses` row — it labels one attempt, so a
re-analysis starts unvoted — and `GET /v1/meals/:id` returns it as
`analysis.userFeedback`.
The first correction copies the current AI values into `ai_predicted_json` (if not already
set), sets `is_user_corrected = 1` and `corrected_at`. `ai_predicted_json` is never
overwritten afterwards. Optionally the correction is written into the caller's `user_foods`
(`?learn=true`, default true) so the same dish resolves correctly next time.

### 5.3 Food lookup
| Method | Path | Notes |
|---|---|---|
| GET | `/v1/foods/search?q=` | hybrid BM25+vector+RRF, merged with the caller's `user_foods` |
| GET | `/v1/foods/barcode/:code` | `200` with the food, or `404 BARCODE_NOT_FOUND` **and** an upsert into `barcode_scan_misses` (`scan_count += 1`). The app shows "chưa có dữ liệu"; an admin adds it later. |
| GET/POST | `/v1/me/foods` · PATCH/DELETE `/v1/me/foods/:id` | personal food base, incl. recipes |

### 5.4 Daily view & planning
| Method | Path | Notes |
|---|---|---|
| GET | `/v1/nutrition/daily?date=YYYY-MM-DD` | consumed vs BMR/TDEE, macro split, deficit |
| GET | `/v1/nutrition/range?from=&to=` | chart series |
| GET | `/v1/meal-plans?date=` | coach suggestions for the day |
| POST | `/v1/meal-plans/generate` | `{ date, mealTypes[] }` → generates from goals + conditions + training load + history |
| PATCH | `/v1/meal-plans/:id` | `{ status: accepted | skipped }` |

---

## 6. Training

| Method | Path | Notes |
|---|---|---|
| POST | `/v1/workouts` | start/complete a session; `id` may be client-generated. `source: in_app \| manual_entry` |
| PATCH | `/v1/workouts/:id` | finish, edit, or soft-delete |
| GET | `/v1/workouts?from=&to=&activityTypeId=` | feed |
| GET | `/v1/workouts/:id` | session + stream summary + splits + zone summary + sets |
| PUT | `/v1/workouts/:id/stream` | upload the sample stream: `{ assetId, sampleCount, sampleIntervalS }`. Server derives polyline, bounds, downsampled series, splits, and time-in-zone, then runs PR detection. |
| GET/PUT | `/v1/workouts/:id/sets` | strength sets (bulk replace) |
| GET | `/v1/training/zones` | current HR zones + how they were derived |
| POST | `/v1/training/zones/recalculate` | after an age or max-HR change |
| GET | `/v1/training/records` | current PRs (`is_current = 1`) |
| GET | `/v1/training/records/:metric/history` | progression chart |

**HR zones** — default `maxHR = 220 − age`, or `user_profiles.max_heart_rate_override`.
Z1 50-60%, Z2 60-70%, Z3 70-80%, Z4 80-90%, Z5 90-100% of max HR. A new set is inserted with
a fresh `effective_from`; old rows stay so historical workouts keep their original zones.

**PR detection** runs after every completed session: fastest 1k/5k/10k/half/full from the
split series, longest distance/duration, and per-exercise max weight/reps/volume. A beaten
record is set `is_current = 0` and the new row records `previous_value`.

---

## 7. Sleep

| Method | Path | Notes |
|---|---|---|
| POST | `/v1/sleep/sessions` | `{ id?, source, startedAt, endedAt, localDate, stages[], events[] }` — the app uploads a whole night at once |
| GET | `/v1/sleep/sessions?from=&to=` | list |
| GET | `/v1/sleep/sessions/:id` | session + hypnogram + audio events |
| PATCH | `/v1/sleep/sessions/:id` | manual correction of start/end |
| GET | `/v1/sleep/debt` | `{ targetSeconds, windowDays: 14, rollingDebtSeconds, byDay: [...] }` |
| GET/POST | `/v1/sleep/reminders` · PATCH/DELETE `/v1/sleep/reminders/:id` | bedtime / wake-up nudges |
| POST | `/v1/sleep/events/:id/transcribe` | ASR on a `sleep_talk` clip (`AI_ASR_MODEL`) |

- Wearable present ⇒ `source = health_sync`, stages come from the device.
- No wearable ⇒ `source = phone_mic`; the phone classifies stages on-device from mic + motion
  and sets `stages_are_estimated = 1`. Stage vocabulary is identical either way
  (`awake` / `light` / `deep` / `rem`), so charts do not branch.
- Each snore / sleep-talk moment is one `sleep_audio_events` row with its own R2 clip,
  **kept indefinitely**.
- **Sleep debt**: fixed personal target (`user_profiles.target_sleep_minutes`), accumulated
  over a rolling 14-day window ending on the given local date. Recomputed nightly and after
  any sleep write.

---

## 8. Wearable sync (Apple Health / Health Connect)

Read on-device; the server stores no OAuth token.

| Method | Path | Notes |
|---|---|---|
| GET/PUT | `/v1/health/connection` | platform + granted scopes + enabled flag |
| GET | `/v1/health/cursors` | per data type high-water marks, so the client only sends new samples |
| POST | `/v1/health/sync` | batch upload `{ workouts[], sleep[], bodyMetrics[], dailyActivity[] }`; dedup by `(source, externalId)`; advances the cursors |

When no connection is enabled: steps/energy are estimated from logged workouts
(MET × duration × kg) plus the activity-level baseline, and rows are marked `isEstimated`.

---

## 9. AI coach

| Method | Path | Notes |
|---|---|---|
| GET/POST | `/v1/coach/conversations` | list / create |
| GET | `/v1/coach/conversations/:id/messages` | thread |
| POST | `/v1/coach/conversations/:id/messages` | `{ content }` → SSE stream of the reply; the persisted assistant row stores the context snapshot + token counts |
| GET | `/v1/coach/insights?from=&to=` | auto-generated daily/weekly insights |
| POST | `/v1/coach/insights/:id/read` | mark read |

Every turn injects a compact context block: profile, active goals, chronic conditions,
today's nutrition balance, the last 7 days of training load, and sleep debt.

---

## 10. Social / moments (Locket)

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/friends` | accepted friends (both directions) |
| GET | `/v1/friends/requests` | incoming + outgoing pending |
| POST | `/v1/friends/requests` | `{ email }` or `{ userId }` |
| POST | `/v1/friends/requests/:id/accept` · `/decline` | |
| DELETE | `/v1/friends/:userId` | unfriend / block |
| POST | `/v1/moments` | `{ photoAssetId, caption?, visibility, linkedMealLogId?, linkedWorkoutSessionId? }` |
| GET | `/v1/moments/feed?cursor=` | friends' moments, newest first |
| GET | `/v1/moments/widget` | **the home-screen widget endpoint**: newest unseen moment per friend, minimal payload, `Cache-Control: private, max-age=60` |
| POST | `/v1/moments/:id/view` · `/react` | seen + emoji reaction |
| DELETE | `/v1/moments/:id` | soft delete |

---

## 11. Admin API (`/v1/admin/*`, role = admin)

Consumed by the Vue admin panel.

| Method | Path | Notes |
|---|---|---|
| GET | `/v1/admin/stats` | counts: users, foods, pending barcode misses, KB docs, meals analysed today, AI failure rate |
| GET | `/v1/admin/foods?q=&source=&verified=&cursor=` | list/search |
| POST | `/v1/admin/foods` | create (`source: admin_barcode` when a barcode is supplied, else `admin_manual`); queues embedding |
| GET/PATCH/DELETE | `/v1/admin/foods/:id` | edit; any change to name/brand/category re-queues the embedding |
| POST | `/v1/admin/foods/:id/verify` | flips `is_verified` |
| POST | `/v1/admin/foods/import` | CSV/JSON bulk import, returns a per-row result report |
| GET | `/v1/admin/barcode-misses?status=pending&cursor=` | the work queue, most-scanned first |
| POST | `/v1/admin/barcode-misses/:id/resolve` | body = a full food payload → creates the food, links `resolved_food_id`, sets `status=resolved` |
| POST | `/v1/admin/barcode-misses/:id/reject` | `{ adminNote }` |
| GET/POST | `/v1/admin/kb-documents` | RAG corpus CRUD |
| GET/PATCH/DELETE | `/v1/admin/kb-documents/:id` | edits mark `embedding_status = pending` |
| POST | `/v1/admin/kb-documents/:id/reindex` · `/v1/admin/kb-documents/reindex-all` | embed via `AI_EMBEDDING_MODEL`, upsert into Vectorize, store `vectorize_id` |
| POST | `/v1/admin/search/preview` | `{ q }` → the BM25 list, the vector list, and the fused RRF list side by side, for tuning retrieval |
| GET/POST/PATCH | `/v1/admin/activity-types` | catalog |
| GET/POST/PATCH | `/v1/admin/exercises` | catalog |
| GET/PUT | `/v1/admin/translations?entityType=&entityId=` | i18n strings |
| GET | `/v1/admin/users?q=&cursor=` | read-only list |
| PATCH | `/v1/admin/users/:id/role` | promote/demote admin |

---

## 12. Cron

| Schedule | Job |
|---|---|
| `*/15 * * * *` | due sleep reminders (per-user local time), orphan media sweep, embedding queue drain |
| `0 19 * * *` (UTC ⇒ 02:00 ICT) | nightly rollups: `daily_nutrition_summaries`, `sleep_debt_daily`, `daily_activity_summaries`, then coach insight generation |

---

## 13. Backend file layout (ownership contract)

```
backend/src/
  index.ts                 # Hono app, CORS, error handler, mounts every router, scheduled()
  env.d.ts                 # Bindings + Vars types
  config/models.ts         # model ids + search tuning, read from env with defaults
  db/client.ts             # drizzle(d1) factory
  db/schema/*.ts           # DONE — source of truth
  lib/{ids,jwt,google,time,http,errors,crypto}.ts
  middleware/{auth,admin,error}.ts
  services/
    foodSearch.ts          # BM25 + Vectorize + RRF
    vectorize.ts           # embed + upsert + query
    mealAnalysis.ts        # vision -> components -> resolution -> persistence
    nutritionMath.ts       # BMR / TDEE / daily rollup
    workoutStream.ts       # polyline, downsample, splits, time-in-zone
    personalRecords.ts     # PR detection
    sleepDebt.ts           # 14-day rolling window
    coach.ts               # context builder + chat + insights
    push.ts                # FCM
  routes/
    auth.ts  me.ts  catalog.ts  media.ts
    nutrition.ts  training.ts  sleep.ts  health.ts  coach.ts  social.ts
    admin/{index,foods,barcodes,kb,catalog,users,stats}.ts
```
Every route module `export default new Hono<AppEnv>()` and is mounted by `index.ts`.
