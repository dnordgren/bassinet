# bassinet

A self-hosted, offline-first PWA baby tracker. Rails 8 + Hotwire on the front,
DynamoDB on the back, sockets for live co-parenting.

Named for the thing the baby is in, since it tracks the thing the baby does in it.

> **Status: phase 2 — logging works.** You can add a child and log diapers,
> feeds, sleep, pumping, growth and notes, then edit, delete and undo them.
> Offline queue, live sync and PWA polish are phases 4–6; the data layer they
> will use already exists.

## Docs

| Doc | What's in it |
| --- | --- |
| [docs/SPEC.md](docs/SPEC.md) | Scope, features, architecture, API surface, roadmap |
| [docs/data-model.md](docs/data-model.md) | DynamoDB access patterns and item layout |
| [docs/sync-protocol.md](docs/sync-protocol.md) | Offline queue, cursor sync, conflict rules |
| [docs/auth.md](docs/auth.md) | Google sign-in and the iOS standalone handoff |
| [docs/setup-google-oauth.md](docs/setup-google-oauth.md) | Console-click steps for the Google Cloud project |
| [docs/pwa-ios.md](docs/pwa-ios.md) | iOS PWA constraints we have to design around |

## Stack

- **Rails 8.1** — Hotwire (Turbo 8 + Stimulus), importmaps, Propshaft
- **DynamoDB** — single table; domain data never touches ActiveRecord
- **SQLite (Rails plumbing only)** — four files under `storage/` for Solid Cable,
  Solid Cache and Solid Queue. Domain data lives in DynamoDB, not here. No Redis.
- **Cloudflare Tunnel + Docker** — self-hosted on a home box, no open ports

Live at `https://bassinet.nordg.ren`.

## Never-again list

- No Postgres, no relational store for domain data. Baby records live in DynamoDB
  or they don't exist. (SQLite is present but is Rails plumbing only — see
  `docs/SPEC.md` §4.2.)
- No Devise. Auth is hand-rolled and small.
- No Redis. Solid Cable over the SQLite file does the job.
- No native wrapper. If it needs Xcode, it's out of scope.

## Runner-up names

If `bassinet` gets vetoed: `hootenanny`, `chuckleberry`, `babygoats`,
`diaperindex`, `the-other-berry`.

## Getting started

```bash
mise install          # Ruby 4.0.9 + Java 25 (DynamoDB Local)
gem install rails     # if you don't have rails on PATH
bin/ddb-download      # fetch DynamoDB Local (jar, ~49MB, gitignored)
bin/ddb-start         # leave running in its own terminal
bin/ddb-create        # create the table + 2 GSIs
bin/rails server      # http://localhost:3000
bundle exec rspec     # 152 examples, boots its own DB on a random port
```

Sign-in needs a Google OAuth client — see `docs/setup-google-oauth.md`. Without
it the app boots, renders, and tells you it's unconfigured rather than failing
at the button.

No Redis, no Postgres. Production is a home box behind a Cloudflare Tunnel —
see `docs/SPEC.md` §9.1.

## Decisions log

| Date | Decision |
| --- | --- |
| 2026-11-09 | Name: `bassinet` |
| 2026-11-09 | Domain: `bassinet.nordg.ren` |
| 2026-11-09 | Host: self-hosted home box, Cloudflare Tunnel |
| 2026-11-09 | AWS: existing account, `us-east-1` |
| 2026-11-09 | Google-only auth in v1; magic link deferred |
| 2026-11-09 | Phase 1 done: data layer + auth, 129 specs |
| 2026-11-25 | Phase 2 done: child creation and event logging, 152 specs |

## What works today

- **Sign in with Google** — including the iOS handoff for an installed PWA.
- **Add a child** — name, birth date, timezone, units. Up to 10 per household.
- **Log events** — one-tap tiles for diaper, bottle and nursing; detail forms for
  feed, sleep, pump, growth and note.
- **Timers** — sleep and nursing start a clock; a banner shows it running with a
  Stop button, and stopping records the duration.
- **Day view** — per-day timeline with type filters and previous/next navigation.
- **Edit, delete, undo** — soft deletes with a five-second undo toast; the
  tombstone is cleared rather than the row recreated.

Everything is scoped to the household at the repository layer, and every write
is validated against a per-type schema (`Bassinet::EventPayload`) before it
reaches DynamoDB.

Not built yet: invites and caregiver roles (phase 3), live co-parenting updates
(phase 4), the offline outbox (phase 5), and PWA install polish (phase 6).
