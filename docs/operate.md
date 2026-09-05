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

Not deployed yet. Target shape: `fly deploy` on fly.io region `sjc`, one machine, mTLS listener at `[::]:8200`, sidecar Tailscale for operator peers. Config lives in a `config-fabric.exs` (Elixir) that mirrors what `service-openbao/config-fdb.hcl` does today. The switch is at the transport layer: peers change their `BAO_ADDR` env from `weftspun-bao.internal:8200` to `weftspun-sqlar-cas.internal:8200`.

## What this service DOES NOT do

- Authentication / cert issuance — that stays at OpenBao
- Identity / entity management — OpenBao's identity engine still owns that
- Passthrough of arbitrary secrets — only the sqlar-cas engine is exposed

The service is a **read gateway** into a sqlar-cas store with a Bao-shaped API. Writes come through Bao's mediation on the ingest side.
