# DynamoDB data model

Single table: **`bassinet`**. No SQL anywhere in the app.

- Billing mode: `PAY_PER_REQUEST`
- PITR: on
- Deletion protection: on
- Encryption at rest: AWS-managed (default)

> **Local dev note:** DynamoDB Local does not support GSIs with the same
> create-time flags as AWS in every version — the create script
> (`bin/ddb-create`) targets the AWS API and works against Local too, but
> `ProvisionedThroughput` on GSIs must be omitted under
> `PAY_PER_REQUEST`. Keep the script flag-driven instead of hand-editing.

---

## 1. Table layout

```
Table: bassinet
  PK  (String)  partition key
  SK  (String)  sort key

  GSI1
    GSI1PK (String)
    GSI1SK (String)

  GSI2
    GSI2PK (String)
    GSI2SK (String)
```

All items carry `entity` (a discriminator), `created_at`, `updated_at`, and
`version` (monotonic counter, bumped on every write).

---

## 2. Items

### 2.1 Household

```
PK = HOUSEHOLD#<household_id>
SK = META
entity      = "household"
name        = "Nordgren"                 # display only
owner_id    = <user_id>
created_at  = <epoch_ms>
updated_at  = <epoch_ms>
deleted_at  = null
```

### 2.2 Member

```
PK = HOUSEHOLD#<household_id>
SK = MEMBER#<user_id>
entity      = "member"
user_id     = <user_id>
role        = "owner" | "caregiver"
display_name= "Derek"
email       = "derek@..."   # display convenience only; auth by sub
avatar_url  = "https://..."
joined_at   = <epoch_ms>
updated_at  = <epoch_ms>
deleted_at  = null

GSI2PK = USER#<user_id>
GSI2SK = HOUSEHOLD#<household_id>
```

`GSI2` exists solely so login can answer "which households does this user
belong to?" without a scan.

### 2.3 Invite

```
PK = HOUSEHOLD#<household_id>
SK = INVITE#<token_hash>
entity      = "invite"
role        = "caregiver"
created_by  = <user_id>
expires_at  = <epoch_ms>
claimed_by  = <user_id> | null
claimed_at  = <epoch_ms> | null
```

`token_hash` = SHA-256 of the 8-char token. The plaintext token exists only in
the invite link; never stored. Expired invites are cleaned up lazily by the read
path (any `INVITE#` older than 30 days gets deleted opportunistically on
household settings load).

### 2.4 Child

```
Primary key:
PK = CHILD#<child_id>
SK = META

entity        = "child"
household_id  = <household_id>       # denormalized for scoping checks
name          = "Mabel"
birth_date    = "2026-11-01"         # date only, no time
photo_url     = null
timezone      = "America/Chicago"
units         = "metric" | "imperial"
archived_at   = null
created_at, updated_at, deleted_at, version

GSI2 (household → children):
GSI2PK = HOUSEHOLD#<household_id>#CHILD
GSI2SK = CHILD#<child_id>#<archived_at or 0>
```

An item gets exactly one GSI2 key pair, so the child list and the user→households
lookup both live on GSI2 (disambiguated by `entity`); GSI1 is reserved for the
event timeline. Sorting children by `<archived_at>#<child_id>` puts live children
(`0`) first and archived ones at the end.

Sorting by `archived_at` (0 for live) keeps archived children at the end, and
lets us filter "live only" with a sort-key condition.

### 2.5 GSI assignment

| GSI | Purpose | PK | SK |
| --- | --- | --- | --- |
| GSI1 | events by child, time-ordered | `CHILD#<cid>` | `EVENT#<ts>#<eid>` |
| GSI2 | household → children, user → households | see §§2.2, 2.4 | see §§2.2, 2.4 |

GSI2 carries two entity families. That's intentional; the `entity` attribute
disambiguates in application code.

### 2.6 Event

```
PK = CHILD#<child_id>
SK = EVENT#<epoch_ms padded to 15>#<event_id>
entity       = "event"
event_id     = <uuidv7>              # client-generated
household_id = <household_id>
child_id     = <child_id>
type         = "diaper" | "feed" | "sleep" | "pump" | "growth" | "note"
occurred_at  = <epoch_ms>            # when it happened (client clock, corrected)
started_at   = <epoch_ms> | null     # sleep/nursing/pump
ended_at     = <epoch_ms> | null
duration_s   = <int> | null
payload      = <map>                 # type-specific, see §2.7
note         = <string> | null
author_id    = <user_id>
source       = "web" | "ios-pwa" | "sync"
created_at   = <epoch_ms>            # server receipt
updated_at   = <epoch_ms>            # server, monotonic
deleted_at   = <epoch_ms> | null
version      = <int>

GSI1PK = CHILD#<child_id>
GSI1SK = EVENT#<epoch_ms padded>#<event_id>
```

**Why the epoch is zero-padded to 15 digits:** 15 digits covers up to year 33658,
so lexicographic ordering matches numeric ordering, forever. `occurred_at` drives
the sort key; `updated_at` drives delta sync. They are different clocks on
purpose.

**Correction of clock skew:** clients send `occurred_at` from their device clock
plus `client_skew_ms` measured against `Date` response headers. Server applies
`occurred_at = sent_occurred_at + client_skew_ms`, clamped to
`[now - 72h, now + 5m]`. Anything outside the clamp comes back as a validation
error rather than silently landing in 2031.

### 2.7 Event payload shapes

Validated with `dry-schema` (or hand-rolled; it's six small schemas) *before* the
DynamoDB write. `payload` is a DynamoDB Map — number values must be serialized
as Number type, strings as String; the repository handles that conversion.

```ruby
diaper: { kind: enum(wet dirty mixed dry), notes: optional(string) }

feed: {
  method: enum(bottle nursing solids tube),
  amount_ml: optional(number, 0..2000),
  side: optional(enum(left right both)),
  duration_s: optional(integer, 0..21600),
  foods: optional(array(string, max 20)),
  notes: optional(string),
}
# method=bottle  → amount_ml required
# method=nursing → side + duration_s required
# method=solids  → foods required, min 1

sleep: {
  quality: optional(enum(good fair poor)),
  location: optional(enum(crib bassinet bed stroller car carrier other)),
  notes: optional(string),
}
# started_at required; ended_at optional (running timer)

pump: {
  amount_ml_left: optional(number),
  amount_ml_right: optional(number),
  duration_s: optional(integer),
  notes: optional(string),
}

growth: {
  weight_g: optional(number),
  height_mm: optional(number),
  head_circumference_mm: optional(number),
}
# at least one required

note: { body: string(1..2000) }
```

---

## 3. Access patterns

Every read the app performs, and the call that serves it.

| # | Access pattern | Operation |
| --- | --- | --- |
| 1 | Household by id | `GetItem PK=HOUSEHOLD#<hid> SK=META` |
| 2 | Members of a household | `Query PK=HOUSEHOLD#<hid> begins_with(SK,"MEMBER#")` |
| 3 | Households for a user | `Query GSI2 GSI2PK=USER#<uid>` |
| 4 | Invite by token hash | `GetItem PK=HOUSEHOLD#<hid> SK=INVITE#<hash>` (hid carried in link) |
| 5 | Children in a household | `Query GSI2 GSI2PK=HOUSEHOLD#<hid>#CHILD` |
| 6 | Child by id | `GetItem PK=CHILD#<cid> SK=META` |
| 7 | Today's events for a child | `Query GSI1 GSI1PK=CHILD#<cid>` + `SK between EVENT#<start> and EVENT#<end>` |
| 8 | Delta sync | `Query PK=CHILD#<cid>` filtered `updated_at > cursor`, or `GSI1` for ordering — see §4 |
| 9 | Running timer for a child | `Query GSI1 CHILD#<cid> desc limit 5`, client-side filter on `ended_at=null` |
| 10 | Single event | `GetItem PK=CHILD#<cid> SK=EVENT#<ts>#<eid>` (ts and eid both in the client) |

**Pattern 8 is the tricky one.** Delta sync wants *changes ordered by
`updated_at`*, but the primary sort key is `occurred_at`. Options:

- **A. Full scan of the child partition.** Works to ~50k events, costs a handful
  of RCUs with `ConsistentRead=false`. For a baby (10 events/day × 365 × 3 years
  ≈ 11k items) this is genuinely fine — one partition, a few hundred KB.
- **B. Add a `GSI3` with `GSI3PK = CHILD#<cid>#SYNC`, `GSI3SK = <updated_at>#<event_id>`.** Every write touches it. Cleaner at scale, one more GSI to maintain and one more write cost.

**Decision: A for v1.** A baby tracker will never have enough rows for the
partition-size argument to matter. Document B in the code as the escape hatch,
number the revision, and revisit if a partition passes 100k items. This keeps
the GSI count at two and every write at one WCU.

**Deletes:** soft delete writes `deleted_at` + bumps `updated_at` + `version`.
The item stays in the partition, so delta sync naturally reports it. Hard
deletes happen only for whole-child purge (account deletion), which is a
batched `BatchWriteItem` over the partition.

---

## 4. Cursor semantics

The sync cursor is `(updated_at, event_id)` — a compound cursor, encoded
base64url as `"<updated_at>:<event_id>"`.

Why not just `updated_at`: two writes can land in the same millisecond (a queued
batch replaying). Sorting by `(updated_at, event_id)` is total and stable, so a
client resuming mid-batch never skips or double-applies an item permanently.

Server side, the query is the partition scan filtered on the tuple. Implementation
detail: scan `PK=CHILD#<cid>`, `FilterExpression` on `entity = "event"`, paginate
at 200 items, and *post-filter* the tuple in Ruby rather than trying to express
it in DynamoDB, because the SDK's sort-key condition applies to `SK`, not
`updated_at`. That means a full-partition read every sync.

**This is the v1 tradeoff and it's called out deliberately.** A baby tracker
syncs a partition of a few thousand items; a 200-item page scan over ~2MB of
data is ~8 RCUs. That's free. When it stops being free, flip to GSI3 (§3-B).

---

## 5. Item size & limits

- All items are far under 400KB. A note body caps at 2KB by validation.
- No item collections (transactions). Household creation writes 3 items
  (household, member, child) via `TransactWriteItems` so a partial failure can't
  leave an orphan member without a household.
- Invite claim is a conditional write: `attribute_exists(PK) AND claimed_by = NULL AND expires_at > now`.
  That's the one place a race genuinely matters (two people tapping the same link).
- Event creation is a `PutItem` with `ConditionExpression: attribute_not_exists(PK)#and attribute_not_exists(SK)`
  — the idempotency guarantee for replayed outbox items. On
  `ConditionalCheckFailedException` we read the existing item and return it,
  treating the replay as a success.

---

## 6. Repository layer

`app/models/repository.rb` base class:

```ruby
class Repository
  TABLE = "bassinet"

  def put(item, condition: nil)
  def get(pk, sk, consistent: false)
  def query(**opts)
  def transact_write(items)
  def batch_write(items)
  # attribute marshalling: String/Integer/Float/Bool/nil/Array/Hash ↔ SDK types
end
```

Concrete repos: `HouseholdRepo`, `MemberRepo`, `InviteRepo`, `ChildRepo`,
`EventRepo`. Each takes `household_id` as a required constructor/kwarg scope.
**A repo method that can return data for a child it wasn't scoped to is a bug.**
There's a test for that: `spec/repos/scoping_spec.rb` tries every public method
with a child from another household and asserts `NotFound`.

---

## 7. Local DynamoDB (dev/test)

`docker-compose.yml`:

```yaml
services:
  dynamodb:
    image: amazon/dynamodb-local:2.5.2
    command: ["-jar", "DynamoDBLocal.jar", "-sharedDb", "-dbPath", "/data"]
    ports: ["8000:8000"]
    volumes: ["./db/dynamodb-local:/data"]
```

`bin/ddb-create` creates the table + both GSIs against
`AWS_ENDPOINT_URL=http://localhost:8000` with dummy creds. Test suite truncates
by deleting/recreating the table per run (`-sharedDb` makes that cheap), or
better, by using unique table names per test process — `bassinet-test-<pid>`.
That's simpler and parallel-safe.

AWS SDK config in `config/initializers/aws.rb`:

```ruby
Aws.config.update(
  region: ENV.fetch("AWS_REGION", "us-east-1"),
  endpoint: ENV["AWS_ENDPOINT_URL"],          # nil in prod
  credentials: ENV["AWS_ENDPOINT_URL"] ?
    Aws::Credentials.new("local", "local") :
    Aws::Credentials.new(ENV["AWS_ACCESS_KEY_ID"], ENV["AWS_SECRET_ACCESS_KEY"])
)
```
