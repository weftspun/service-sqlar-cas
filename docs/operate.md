# Operating service-sqlar-cas

An Elixir service that feels like OpenBao with a native sqlar-cas engine. Speaks the same route shape peers already use for Bao (`/v1/sys/health`, `/v1/sys/mounts`, `/v1/sqlar-cas/<action>`), backed by SQLite through fabric-store's FDB VFS.

## Local dev

```
cd 7-service/service-sqlar-cas
mix deps.get
mix compile
mix test
SQLAR_CAS_DB=priv/dev.sqlite SQLAR_CAS_PORT=8200 iex -S mix
```

Health check:
```
curl -s http://localhost:8200/v1/sys/health | jq .
```

## Environment

| var | default | note |
|---|---|---|
| `SQLAR_CAS_PORT` | `8200` | Bandit HTTP listener port |
| `SQLAR_CAS_DB` | `priv/sqlar_cas.sqlite` | SQLite path; `:memory:` for tests; `fabric://sqlar-cas` for FDB-VFS in prod |

## Route surface

| method | path | returns |
|---|---|---|
| GET | `/v1/sys/health` | `{status, engine}` |
| GET | `/v1/sys/mounts` | mount map — `sqlar-cas/` type `sqlar-cas` |
| GET | `/v1/sqlar-cas/readers/:object` | expanded reader set (ReBAC userset recursion) |
| GET | `/v1/sqlar-cas/sqlar/:name` | sqlar row metadata (name, size, dek_id hex) |
| GET | `/v1/sqlar-cas/chunk/:hash_hex` | raw chunk ct bytes |

## Ingest side (not routed)

Wraps + chunks + relationships land in the store via `Mix.Tasks.SqlarCas.Ingest` (a mix task, dev/staging) or the Bao write path in prod. The HTTP layer is READ-only — nothing that touches the wire mutates state.

## Storage modes

- **Dev**: `SQLAR_CAS_DB=priv/dev.sqlite` — plain local file
- **Test**: `:memory:` (see `test/test_helper.exs`)
- **Prod**: fabric-store VFS behind SQLite; pages live in the same FDB cluster that backs the workspace's OpenBao. `SQLAR_CAS_DB=fabric://sqlar-cas` selects that path (once the fabric-store Elixir NIF or port lands)

## Falsifiability controls (in `test/`)

Every read-path feature carries a negative control that must fail:

- **`aead_decrypt` on ct tamper** — flip a byte, assert `:error`
- **`aead_decrypt` on aad tamper** — different aad, assert `:error`
- **ReBAC cycle guard** — mutual usersets `a#reader → b#reader → a#reader`, assert empty result (not stack overflow)
- **No-grant object** — never-granted object, assert empty reader set
- **Wrong recipient key** — vector unwrap with random priv, assert `:error`
- **Tampered chunk** — flip a byte in `sqlar_chunks.ct`, assert reassembly `:error`

The controls exist because a check that only ever sees the true input has never shown it can fail — falsifiability requires the negative test alongside the positive one.

## Deploy shape (future)

Not deployed yet. Target shape: `fly deploy` on fly.io region `sjc`, one machine, mTLS listener at `[::]:8200`, sidecar Tailscale for operator peers. Config lives in a `config-runtime.exs` (Elixir). Peers wire to `weftspun-sqlar-cas.internal:8200` — separate hostname from `weftspun-bao.internal:8200`; nothing pretends to be Bao.

## Storage: Tigris S3, zero-trust offline

Chunks live in a Tigris bucket on fly.io. **The zero-trust property is enforced by the wire crypto, not by an online gate** — reads and writes work correctly even when both this service AND OpenBao are offline.

### Where the guarantee lives

| layer | who enforces | offline behavior |
|---|---|---|
| Confidentiality (chunk bytes) | AEAD envelope + X25519 wraps | Cached wraps + cached file_keys keep decrypting |
| Integrity (chunk bytes) | SHA-512/256(ct) content addressing + Poly1305 tag | Tampered bytes hash to a different key + fail AEAD tag |
| Read authorization (who holds a wrap) | X25519 wrap → recipient private key | Wraps travel with the .sqlite / this service's DB; private keys stay in each peer's keystore |
| Write integrity (bogus writes) | Chunk key = SHA-512/256(ct) | Garbage writes land at their own garbage hash; can't overwrite a legit chunk |
| Write ReBAC (new readers) | Bao ReBAC decision at wrap insertion | REQUIRES Bao online — this is the one operation that cannot be done offline |

### Access flow

```
peer  --S3 creds (cached)-->  Tigris S3 (private)   ← reads + writes, no service in the byte path
                                     ^
                                     |
peer  --mTLS-->  service-sqlar-cas   |   ← wrap insertion + ReBAC lookups (Bao-mediated when up)
                        ^            |
                        |            |
                        +---Bao--(ReBAC decision at wrap-write time only)
```

Peers hold Tigris S3 credentials locally (issued by Bao's AWS secrets engine when online; cached for the outage window). They fetch and PUT chunks directly against Tigris. The service is out of the byte path entirely.

**Why permissive S3 is safe here**: chunks are AEAD-encrypted with a file_key that only wrap-holders can unwrap. A peer without a wrap can DOWNLOAD any chunk from S3 and learn nothing (opaque ct). A peer without the file_key can UPLOAD any bytes to S3 and just land at a hash nobody's caibx references (wasted space, no security impact). The bucket does not need per-request ReBAC gating for confidentiality to hold — the crypto handles that.

**What the bucket policy DOES need**: mTLS cert as a `weftspun-fleet` peer (basic fleet-membership auth), plus per-peer rate limits to bound waste-space DoS. That's it — no fine-grained ReBAC tuples at the S3 layer.

### What the service is actually for

- **Wrap issuance**: `POST /v1/sqlar-cas/wraps` — insert a new wrap row for a recipient. Requires Bao ReBAC check (writer authorized to add this reader). Only online operation.
- **Wrap enumeration**: `GET /v1/sqlar-cas/readers/:object` — expand a userset. Cached locally; Bao consulted on cache miss / TTL expiry.
- **Chunk-hash presign** (optional): `POST /v1/sqlar-cas/chunk/presign` — service signs an S3 URL for a peer that doesn't hold S3 creds. Rare; most peers hold their own creds.
- **Diagnostic reads**: `GET /v1/sqlar-cas/sqlar/:name` — sqlar row metadata; reads a wrap manifest.

### Credential provenance

- **Preferred**: Bao's AWS secrets engine issues short-lived S3 creds (~1h) to each peer directly. Peer holds cert → gets creds → uses them for the TTL window. Rotates before expiry.
- **Fallback for the pre-Bao-integration phase**: static `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_ENDPOINT_URL_S3=https://fly.storage.tigris.dev` in each peer's fly secrets.

## ReBAC lookups

The service does not own identity. It reads ReBAC state from Bao at wrap-write time, sharing credentials with the rest of the fleet:

- Service has its own mTLS cert issued by the same fleet CA as every peer.
- On wrap-write (a peer-initiated `POST /v1/sqlar-cas/wraps`), calls Bao's identity + relationships API to check `writer(current_peer, object)`, then inserts the wrap row.
- On enumerate (rare — most reads don't need this since crypto is the read gate), same call.
- A local cache with a short TTL (~5s) keeps expand hot-paths cheap without stale-permission risk.

`SqlarCas.ReBAC` currently reads a local `relationships` table for dev/test. In prod it swaps to `SqlarCas.ReBAC.Bao` — same interface, Bao as the source of truth.

## What this service DOES NOT do

- Authentication / cert issuance — that stays at OpenBao
- Identity / entity management — OpenBao's identity engine still owns that
- Passthrough of arbitrary secrets — only the sqlar-cas engine is exposed

The service is a **read gateway** into a sqlar-cas store with a Bao-shaped API. Writes come through Bao's mediation on the ingest side.
