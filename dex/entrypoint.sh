#!/bin/sh
# Dex on Railway — the identity provider Pomerium authenticates against.
#
# Dex takes a config file and nothing else, and two of the values in it cannot
# come from a Railway variable: the admin password has to arrive as a bcrypt
# hash, and the OAuth client secret has to match the one Pomerium derives. Both
# are computed here from variables a deployer actually supplies.
set -eu

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

CONFIG_FILE=/tmp/dex-config.yaml

[ -n "${SECRET_SEED:-}" ]   || die "SECRET_SEED is not set"
[ -n "${ADMIN_EMAIL:-}" ]   || die "ADMIN_EMAIL is not set"
[ -n "${ADMIN_PASSWORD:-}" ] || die "ADMIN_PASSWORD is not set"
[ -n "${DEX_DB_HOST:-}" ]   || die "DEX_DB_HOST is not set - point it at the Postgres service"

: "${PORT:=8080}"
: "${DEX_DB_PORT:=5432}"
: "${DEX_DB_NAME:=railway}"
: "${DEX_DB_USER:=postgres}"
: "${DEX_DB_PASSWORD:=}"
: "${DEX_DB_SSLMODE:=require}"
: "${DEX_CLIENT_ID:=pomerium}"
: "${ADMIN_USERNAME:=admin}"

if [ -z "${DEX_ISSUER_URL:-}" ]; then
  [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ] || die "no public domain yet - generate one for this service, then redeploy"
  DEX_ISSUER_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi
DEX_ISSUER_URL="${DEX_ISSUER_URL%/}"

[ -n "${AUTHENTICATE_SERVICE_URL:-}" ] || die "AUTHENTICATE_SERVICE_URL is not set - Dex needs Pomerium's callback URL"
REDIRECT_URI="${AUTHENTICATE_SERVICE_URL%/}/oauth2/callback"

# --------------------------------------------------------------- secrets ----
# Same derivation Pomerium's entrypoint uses, so the two halves of the OAuth
# client always agree without either service writing the other's environment.
if [ -z "${DEX_CLIENT_SECRET:-}" ]; then
  DEX_CLIENT_SECRET="$(printf '%s' "${SECRET_SEED}:dex-client" | openssl dgst -sha256 -hex -r | cut -d' ' -f1)"
fi

# Go's bcrypt rejects the $2y$ prefix htpasswd emits; the formats are otherwise
# identical, so rewrite the version byte.
DEX_ADMIN_BCRYPT="$(htpasswd -nbBC 10 x "$ADMIN_PASSWORD" | cut -d: -f2- | sed 's/^\$2y\$/\$2a\$/')"
case "$DEX_ADMIN_BCRYPT" in
  '$2a$'*) : ;;
  *) die "failed to bcrypt ADMIN_PASSWORD" ;;
esac
export DEX_ADMIN_BCRYPT

# A stable user id keeps the admin's Dex identity the same across redeploys, so
# anything keyed on the OIDC subject claim survives.
ADMIN_USER_ID="$(printf '%s' "$ADMIN_EMAIL" | openssl dgst -sha256 -hex -r | cut -c1-32 \
  | sed 's/\(........\)\(....\)\(....\)\(....\)\(............\)/\1-\2-\3-\4-\5/')"

yq_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }

{
  printf '# rendered by dex/entrypoint.sh - edit the variables, not this file\n'
  printf 'issuer: %s\n' "$(yq_quote "$DEX_ISSUER_URL")"
  printf 'storage:\n  type: postgres\n  config:\n'
  printf '    host: %s\n' "$(yq_quote "$DEX_DB_HOST")"
  printf '    port: %s\n' "$DEX_DB_PORT"
  printf '    database: %s\n' "$(yq_quote "$DEX_DB_NAME")"
  printf '    user: %s\n' "$(yq_quote "$DEX_DB_USER")"
  printf '    password: %s\n' "$(yq_quote "$DEX_DB_PASSWORD")"
  printf '    connectionTimeout: 15\n'
  printf '    ssl:\n      mode: %s\n' "$DEX_DB_SSLMODE"
  printf 'web:\n  http: 0.0.0.0:%s\n' "$PORT"
  printf 'telemetry:\n  http: 127.0.0.1:5558\n'
  printf 'oauth2:\n  skipApprovalScreen: true\n'
  printf 'staticClients:\n'
  printf '  - id: %s\n' "$(yq_quote "$DEX_CLIENT_ID")"
  printf '    name: Pomerium\n'
  printf '    secret: %s\n' "$(yq_quote "$DEX_CLIENT_SECRET")"
  printf '    redirectURIs:\n      - %s\n' "$(yq_quote "$REDIRECT_URI")"
  printf 'enablePasswordDB: true\n'
  printf 'staticPasswords:\n'
  printf '  - email: %s\n' "$(yq_quote "$ADMIN_EMAIL")"
  printf '    hashFromEnv: DEX_ADMIN_BCRYPT\n'
  printf '    username: %s\n' "$(yq_quote "$ADMIN_USERNAME")"
  printf '    userID: %s\n' "$(yq_quote "$ADMIN_USER_ID")"
} > "$CONFIG_FILE"

# Dex expands $VAR inside connector and storage config values, which would eat a
# database password containing a dollar sign. Nothing here needs expansion.
export DEX_EXPAND_ENV=false

log "issuer=${DEX_ISSUER_URL} redirect_uri=${REDIRECT_URI} db=${DEX_DB_HOST}:${DEX_DB_PORT}/${DEX_DB_NAME}"
log "admin=${ADMIN_EMAIL} (static password, no self-service signup)"
exec dex serve "$CONFIG_FILE"
