# CI / CD

## `ci.yml` — every PR and push to main

| Job | What it proves |
|---|---|
| backend | typecheck, 46 unit tests, migrations + seed apply to a fresh SQLite (including the FTS5 triggers), Worker bundles |
| admin | `vue-tsc` clean, production build, `dist` uploaded as an artifact |
| app | `flutter analyze` clean and `dart format` unchanged |

## `deploy.yml` — push to main, or run manually

D1 migrations apply **before** the Worker deploys, so new code never meets an old
schema. Then the Worker ships, the admin panel builds against production values and
goes to Cloudflare Pages, and `/health` is polled until it answers.

### Required repository secrets

| Secret | Where to get it |
|---|---|
| `CLOUDFLARE_API_TOKEN` | Cloudflare dashboard → My Profile → API Tokens. Needs **Workers Scripts:Edit**, **D1:Edit**, **Workers R2 Storage:Edit**, **Vectorize:Edit**, **Cloudflare Pages:Edit** |
| `CLOUDFLARE_ACCOUNT_ID` | Any Cloudflare dashboard URL, or `npx wrangler whoami` |

### Required repository variables

| Variable | Example |
|---|---|
| `API_BASE_URL` | `https://chiphealth-api.<subdomain>.workers.dev` |
| `ADMIN_API_BASE_URL` | same as above — what the admin panel calls |
| `GOOGLE_WEB_CLIENT_ID` | the OAuth web client id, also listed in the Worker's `GOOGLE_CLIENT_IDS` |
| `GOOGLE_IOS_CLIENT_ID` | optional — `ios-sideload.yml` otherwise takes the 2nd entry of `GOOGLE_CLIENT_IDS` (iOS client, bundle id `vn.chiphealth.app`) |

### Worker secrets (set once with wrangler, not in CI)

```bash
cd backend
npx wrangler secret put JWT_SECRET            # openssl rand -base64 48
npx wrangler secret put GOOGLE_CLIENT_IDS
npx wrangler secret put BOOTSTRAP_ADMIN_EMAILS
npx wrangler secret put WEB_SEARCH_API_KEY    # optional
npx wrangler secret put FCM_SERVICE_ACCOUNT_JSON  # optional
```

Non-secret values (model ids, search tuning) live in `wrangler.toml [vars]` so a
model swap is a reviewable diff rather than a hidden dashboard change.
