# bassinet

A self-hosted, offline-first PWA baby tracker. Rails 8 + Hotwire on the front,
DynamoDB on the back, sockets for live co-parenting.

Named for the thing the baby is in, since it tracks the thing the baby does in it.

> **Status: spec only.** The root commit of this repo is the initial design
> document. No application code exists yet.

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
- **DynamoDB** — single table, no ActiveRecord
- **Redis** — Action Cable pub/sub only (Solid Cable needs SQL; we have none)
- **Cloudflare Tunnel + Docker** — self-hosted on a home box, no open ports

Live at `https://bassinet.nordg.ren`.

## Never-again list

- No Postgres. No SQL. If it needs a relational store, it's in DynamoDB items.
- No Devise (needs ActiveRecord). Auth is hand-rolled and small.
- No native wrapper. If it needs Xcode, it's out of scope.

## Runner-up names

If `bassinet` gets vetoed: `hootenanny`, `chuckleberry`, `babygoats`,
`diaperindex`, `the-other-berry`.

## Getting started

Nothing to run yet. Provisioning notes land here once the skeleton exists.

Dev box needs Ruby 3.4 (via `mise`), Docker (DynamoDB Local + Redis), and a JRE
for the DynamoDB Local jar. Production is a home box behind a Cloudflare Tunnel
— see `docs/SPEC.md` §9.1.

## Decisions log

| Date | Decision |
| --- | --- |
| 2026-11-09 | Name: `bassinet` |
| 2026-11-09 | Domain: `bassinet.nordg.ren` |
| 2026-11-09 | Host: self-hosted home box, Cloudflare Tunnel |
| 2026-11-09 | AWS: existing account, `us-east-1` |
| 2026-11-09 | Google-only auth in v1; magic link deferred |
