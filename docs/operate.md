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

## Storage (future): Tigris S3 in zero-trust mode

Chunks live in a private Tigris bucket on fly.io (`fly storage create` on this app). The bucket is **zero-trust**: no public read, no public list, no unauthenticated GET.

Access flow:

```
peer  --mTLS-->  service-sqlar-cas  --ReBAC-check (Bao)-->  authorize?
                        |                                       |
                        v                                       v
              Tigris S3 (private)  <--S3 creds (service only)---+
                        |
                        v
                  presign URL or stream bytes back to peer
```

Two access strategies, matched to the peer's shape:

1. **Byte-stream through the service** — peer hits `GET /v1/sqlar-cas/chunk/:hash_hex`; service checks ReBAC, streams the S3 body back through its own HTTP response. Simple, no S3 exposure at all, but every byte goes through the service (Bandit is fast enough for chunk-sized bodies).
2. **Presigned URL** — peer hits `GET /v1/sqlar-cas/chunk/:hash_hex?presign=1`; service checks ReBAC, presigns a short-lived (~60s) S3 GET URL, returns it. Peer then fetches direct from Tigris. Better for large-avatar / world payloads; no service in the byte path.

Either way, only the service holds the S3 credentials — peers never see them. Peer authorization is always ReBAC-gated at the service.

Credential provenance for the S3 side:

- **Preferred**: Bao's AWS secrets engine issues short-lived S3 creds to the service. Rotate on TTL (~1h). Service holds a Bao cert, calls `bao read tigris/creds/service-sqlar-cas` at startup + on TTL rollover.
- **Fallback**: static credentials in fly secrets (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3=https://fly.storage.tigris.dev`). Simpler; no rotation. Acceptable for the pre-Bao-integration phase.

## ReBAC lookups (future)

The service does not own identity or relationships. It reads ReBAC state from Bao at authorization time, sharing credentials with the rest of the fleet:

- Service has its own mTLS cert issued by the same CA as every peer.
- On each read that needs authorization, calls Bao's identity + relationships API (or a local cache with a short TTL) to resolve `enumerate_readers(object)`.
- Cache TTL is short (~5s) so revocations propagate fast; the readers set is tiny (a userset expansion), so cache misses are cheap.

The `SqlarCas.ReBAC` module currently reads a local `relationships` table for dev/test. In prod it swaps to `SqlarCas.ReBAC.Bao` — same interface, Bao as the source of truth.

## What this service DOES NOT do

- Authentication / cert issuance — that stays at OpenBao
- Identity / entity management — OpenBao's identity engine still owns that
- Passthrough of arbitrary secrets — only the sqlar-cas engine is exposed

The service is a **read gateway** into a sqlar-cas store with a Bao-shaped API. Writes come through Bao's mediation on the ingest side.
