# Pomerium on Railway

[Pomerium](https://www.pomerium.com/) is an identity-aware reverse proxy: every
request to an upstream application is authenticated against an identity provider
and authorised against a policy, so the application behind it needs no login of
its own.

This repository builds the two images a Railway deployment needs. It is the
source for a Railway template that also provisions Postgres and a demo upstream.

## Services

| Directory | Image built from | Role |
|---|---|---|
| `pomerium/` | `pomerium/pomerium:latest` binary on `debian:bookworm-slim` | both Pomerium roles — the entrypoint reads `SERVICES` |
| `dex/` | `ghcr.io/dexidp/dex:v2.45.1-alpine` | the bundled OIDC identity provider |

Point each Railway service at its Dockerfile with
`RAILWAY_DOCKERFILE_PATH=<dir>/Dockerfile`; the build context is the repository
root either way.

The reference topology is five services:

```
browser ──▶ pomerium  (proxy, authorize, databroker)  ──▶ verify   (private upstream)
   │              │
   │              └── gRPC :5443 ◀── authenticate  (Pomerium, authenticate role)
   └──────────────────────────────▶ dex  (OIDC identity provider)
                                     │
        pomerium + dex ──────────────┴──▶ Postgres
```

`pomerium` and `authenticate` are separate services because each needs its own
public origin and Railway gives one generated domain per service. `verify`
(`pomerium/verify:latest`) is the demo upstream: it renders the identity claims
Pomerium forwarded, which is what proves the whole chain end to end.

## Why a repository rather than plain variables

Two things a Railway variable cannot carry:

* **A matched secret set.** `shared_secret` and `cookie_secret` must be identical
  on both Pomerium services, and the OAuth client secret must be identical on Dex
  and Pomerium. `${{secret(N)}}` is re-evaluated per read and no service can write
  another's environment, so all four are derived here from one `SECRET_SEED`
  (`sha256("<seed>:<purpose>")`). Each has an override variable.
* **The route table.** `routes:` is multi-line YAML; a template variable replaces
  content of that size with placeholder text.

Dex adds a third: it accepts only a bcrypt *hash* for a static password, and no
Railway variable can hash one. `dex/entrypoint.sh` does it at boot, rewriting
htpasswd's `$2y$` prefix to `$2a$` — Go's bcrypt rejects `$2y$`.

## Variables

Supplied by the deployer:

| Variable | Used by | Notes |
|---|---|---|
| `ADMIN_EMAIL` | dex, pomerium, authenticate | the one account Dex creates, and the default policy allow-list |
| `ADMIN_PASSWORD` | dex | bcrypt-hashed at boot; Dex has no self-service signup |
| `SECRET_SEED` | all three | generated; every other secret is derived from it |

Wiring (references, not literals):

| Variable | Value |
|---|---|
| `AUTHENTICATE_SERVICE_URL` | `https://${{authenticate.RAILWAY_PUBLIC_DOMAIN}}` |
| `IDP_PROVIDER_URL` | `https://${{dex.RAILWAY_PUBLIC_DOMAIN}}` |
| `DATABROKER_SERVICE_URL`, `AUTHORIZE_SERVICE_URL` | `http://pomerium.railway.internal:5443` — needed on **every** split-mode service, the authenticate role included |
| `DEX_DB_*` | `${{Postgres.PGHOST}}` and friends |

Routing:

| Variable | Default | Notes |
|---|---|---|
| `UPSTREAM_URL` | `http://verify.railway.internal:8000` | the catch-all route; point it at your own service |
| `UPSTREAM_2_URL` … `UPSTREAM_5_URL` | unset | each needs a matching `UPSTREAM_N_PREFIX` |
| `ALLOWED_EMAILS` | `ADMIN_EMAIL` | comma-separated |
| `ALLOWED_DOMAINS` | unset | comma-separated; allows every address at those domains |

Overrides, for operators who want to supply their own: `SHARED_SECRET`,
`COOKIE_SECRET`, `IDP_CLIENT_SECRET` / `DEX_CLIENT_SECRET`, `POMERIUM_PUBLIC_URL`,
`DEX_ISSUER_URL`.

## Using a different identity provider

Dex exists so the template works with no external signup. To use Google, Okta,
Entra or any other OIDC provider instead, set `IDP_PROVIDER`, `IDP_PROVIDER_URL`,
`IDP_CLIENT_ID` and `IDP_CLIENT_SECRET` on `pomerium` and `authenticate`, register
`https://<authenticate domain>/oauth2/callback` as the redirect URI, and delete
the `dex` service.

## Notes

* Railway terminates TLS at the edge, so both Pomerium services run with
  `INSECURE_SERVER=true` and bind plain HTTP on `$PORT`. An empty host in
  `ADDRESS` makes Envoy bind `::` **and** `0.0.0.0`, so the IPv4 health-check
  prober and an IPv6 private peer are both served.
* `/healthz` is an anonymous 200 on both Pomerium roles and on Dex.
* Databroker state lives in Postgres (`schema pomerium`); Dex uses the default
  schema of the same database. Neither service needs a volume.

Licence: Pomerium is Apache-2.0, Dex is Apache-2.0. This repository only packages
them.
