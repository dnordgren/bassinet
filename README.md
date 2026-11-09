# chuckleberry

A self-hosted, offline-first PWA baby tracker. Rails 8 + Hotwire on the front,
DynamoDB on the back, sockets for live co-parenting.

Named after the obvious inspiration, with a vowel changed and a smirk attached.

> **Status: spec only.** The root commit of this repo is the initial design
> document. No application code exists yet.

## Docs

| Doc | What's in it |
| --- | --- |
| [docs/SPEC.md](docs/SPEC.md) | Scope, features, architecture, API surface, roadmap |
| [docs/data-model.md](docs/data-model.md) | DynamoDB access patterns and item layout |
| [docs/sync-protocol.md](docs/sync-protocol.md) | Offline queue, cursor sync, conflict rules |
| [docs/auth.md](docs/auth.md) | Google sign-in and the iOS standalone handoff |
| [docs/pwa-ios.md](docs/pwa-ios.md) | iOS PWA constraints we have to design around |

## Stack

- **Rails 8.1** — Hotwire (Turbo 8 + Stimulus), importmaps, Propshaft
- **DynamoDB** — single table, no ActiveRecord
- **Redis** — Action Cable pub/sub only (Solid Cable needs SQL; we have none)
- **Kamal 2** — deploy to a single small instance

## Never-again list

- No Postgres. No SQL. If it needs a relational store, it's in DynamoDB items.
- No Devise (needs ActiveRecord). Auth is hand-rolled and small.
- No native wrapper. If it needs Xcode, it's out of scope.

## Runner-up names

If `chuckleberry` gets vetoed: `hootenanny`, `bassinet`, `babygoats`,
`diaperindex`, `the-other-berry`.

## Getting started

Nothing to run yet. Provisioning notes land here once the skeleton exists.
See `docs/SPEC.md` §12 for what's required on the box (Ruby 3.4 via `mise`,
Docker for DynamoDB Local, a JRE for DynamoDB Local's jar).
