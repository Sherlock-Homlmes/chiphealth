# ChipHealth — mobile app (Flutter)

Retro-styled client for the ChipHealth API. See `../api_design.md` for the contract
and `../db_design.dbml` for the data model.

## Verification status

`flutter analyze` is clean for the sleep feature; the only current issue is an
info-level `dart:html` deprecation in `core/api/sse_web.dart` (concurrent work,
unrelated). `flutter test` passes 46/46 including the night-analyzer suite;
`flutter build web --debug` compiles, proving the YAMNet conditional import
keeps the web target alive. Dependencies resolve after `flutter_secure_storage`
moved to `^10.3.2` (9.x clashed with `share_plus >=13` on win32; 11.0.0 wants
the android-37 preview) and `tflite_flutter` pinned to `^0.11.0` (0.12 pulls
`package:jni`, whose CMake build hard-requires an Android NDK).

Not yet verified: running on a real device or emulator, and every platform
integration that needs one — camera, GPS, microphone, the home-screen widget,
Google Sign-In, Apple Health / Health Connect, and the YAMNet classifier itself
(the model file was verified off-device: LiteRT run, input float32[15600],
output [1,521], class indices cross-checked against yamnet_class_map.csv).

An APK build additionally needs ~3 GB free disk for the Android NDK the Flutter
Gradle plugin installs (r27 by default); this sandbox ran out of space there —
`flutter analyze`, `flutter test` and the web build all passed.

## Toolchain

No local SDK required — the image is the toolchain:

```bash
docker volume create chiphealth-pubcache
docker run --rm -v "$PWD":/app -v chiphealth-pubcache:/pubcache \
  -e PUB_CACHE=/pubcache -w /app ghcr.io/cirruslabs/flutter:stable \
  bash -lc "flutter pub get && flutter analyze"
```

The pub cache **must** be a volume: without it each `docker run` starts with an empty
cache and `package_config.json` points at packages that no longer exist, which shows
up as hundreds of bogus "Target of URI doesn't exist" errors.

## Running on a device

```bash
flutter pub get
flutter run \
  --dart-define=API_BASE_URL=http://10.0.2.2:8787 \
  --dart-define=GOOGLE_SERVER_CLIENT_ID=<web client id> \
  --dart-define=GOOGLE_IOS_CLIENT_ID=<ios client id>
```

`10.0.2.2` is how the Android emulator reaches a `wrangler dev` on the host. On a real
device use the machine's LAN IP, and add that origin to the Worker's `ADMIN_ORIGIN`
only if you also open the admin panel from it (the mobile app is not a browser and is
not subject to CORS).

The Google client ids must also appear in the Worker's `GOOGLE_CLIENT_IDS`, or
`/v1/auth/google` will reject the id_token's audience.

## Layout

```
lib/
  core/
    api/          Dio client: bearer header + single-flight refresh on 401
    auth/         Google sign-in, token store (refresh token in the keystore)
    config/       --dart-define values
    format/       metric <-> imperial, durations, local dates
    l10n/arb/     vi + en strings  (see "Known gaps")
    models/       hand-written models, no codegen
    repositories/ one class per API domain
    storage/      UUIDv7, offline outbox
    theme/        retro tokens + ThemeData
  features/       one folder per surface
  widgets/        shared retro widgets
```

## Design decisions worth keeping

- **No codegen.** freezed/json_serializable/drift were dropped so the project builds
  with `flutter pub get` alone. Models are hand-written; the offline outbox is a JSON
  file rather than a local database.
- **The coach only *looks* streamed.** The API answers in one response so the reply can
  be persisted with the context snapshot that produced it. The screen shows staged
  progress ("đang đọc dữ liệu của bạn…") and types the answer in; tapping the bubble
  reveals it instantly. See `features/coach/typing_effects.dart`.
- **Client-minted UUIDv7 ids** for meals, workouts and sleep sessions. The API treats
  POST as an upsert on that id, so an offline log replays safely and never duplicates.
- **The workout stream is one file, not many rows.** The recorder buffers samples and
  uploads NDJSON to R2 at the end; the server derives polyline, splits, time-in-zone and
  PRs. The app never sends per-point rows.
- **Corrections are the product.** `MealDetailScreen` lets the user fix every value the
  AI produced. The original prediction is preserved server-side, so each edit is a
  (prediction, ground truth) pair and also teaches this user's own food base.
- **Units convert only at the edge.** Everything is stored and sent in metric;
  `core/format/units.dart` is the single place imperial rendering happens.
- **A missing barcode is a state, not an error.** Barcodes are admin-entered; a scan
  miss shows "chưa có dữ liệu" and the server records the demand for an admin.

## Known gaps (deliberate, not forgotten)

| Area | State |
|---|---|
| UI strings | Screens hold Vietnamese literals. `lib/core/l10n/arb/*.arb` holds the vi+en catalogue (44 keys, identical sets) and `l10n.yaml` is configured, but screens have not been migrated to `AppL10n` yet. |
| On-device sleep staging | Implemented as a **prior-shaped estimate**, not a measurement: `features/sleep/audio/night_analyzer.dart` builds a per-minute hypnogram from loudness + vocalisation, with 18% deep / 22% REM quotas and circadian weighting. Phone-mic nights already carry `stages_are_estimated` server-side. Short/classifier-less nights still fall back to one `light` block. |
| Snore / sleep-talk detection | Implemented: YAMNet (AudioSet, 521 classes) runs on-device via `tflite_flutter` on every 0.975 s window above the silence floor; snore/talk/cough events coalesce, get 15 s WAV clips (budget: 12 snore clips/night, talk/cough always) and upload through the existing `sleep_audio_clip` media kind. Web keeps the fallback path (no `dart:ffi`). Model: `assets/models/yamnet.tflite`, sha256 `10c95ea3…317de`. Remaining: thresholds need tuning on real beds, and overnight survival behind a locked screen needs an Android foreground service / iOS background-audio mode. |
| Audio playback | `just_audio` is a dependency; the per-event play button is not wired. |
| Image display | Media is served from an authenticated endpoint, so `Image.network` needs an auth header (or a signed-URL endpoint). Moment tiles currently show a placeholder. |
| Apple Health / Health Connect | `POST /v1/health/sync` exists on the server; the on-device readers are not written. |
| Home-screen widget | Native code exists for both platforms and the Dart side pushes data via `home_widget`; not run on a device. |
| Offline outbox | `core/storage/outbox.dart` is written but no screen enqueues into it yet — writes currently fail fast when offline. |
