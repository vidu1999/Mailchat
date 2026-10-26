# Bundled configuration

`env` in this folder is read at startup by `AppConfig.load()` and supplies the
Supabase URL and anon key, so `flutter run` needs no `--dart-define` flags.

| File | Committed | Purpose |
|---|---|---|
| `env.example` | yes | Template. Copy it to `env` and fill in real values. |
| `env` | **no** (gitignored) | Your local credentials. |
| `README.md` | yes | This file. Also keeps the folder present so the declared asset directory exists on a fresh clone and in CI. |

Setup:

```powershell
Copy-Item assets/config/env.example assets/config/env
# then edit assets/config/env
flutter run
```

Why the file is not called `.env`: Flutter's asset bundler skips dotfiles, so
`assets/config/.env` would be silently absent at runtime. A `.env` in the
project root is not read either — `String.fromEnvironment` only sees
`--dart-define`, which is a compile-time value.

Rules:

- Never commit `env`.
- Only the `anon` / public key belongs here. The `service_role` key bypasses
  RLS and must never ship in an app bundle.
- The anon key is embedded in the APK. That is intended (it is a publishable
  key, and every table is protected by RLS), but it is why RLS must stay
  enabled.
- Changes need a full restart (`flutter run` again), not a hot reload.
