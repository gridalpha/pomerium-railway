#!/usr/bin/env bash
# Pomerium on Railway.
#
# Renders the two things a Railway variable cannot carry:
#   * the matched secret set (shared_secret, cookie_secret and the OIDC client
#     secret Dex must agree on), all derived from one SECRET_SEED
#   * the route table, which is multi-line YAML
#
# Everything else is a plain environment variable Pomerium reads itself.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*"; }
die() { printf '[entrypoint] FATAL: %s\n' "$*" >&2; exit 1; }

CONFIG_FILE=/pomerium/config.yaml
SERVICES_VALUE="${SERVICES:-all}"

# ---------------------------------------------------------------- secrets ---
# ${{secret(N)}} cannot produce a value two services must agree on, and no
# service can write another's environment, so every matched secret is derived
# here from a single seed. Each has an override for operators who rotate them
# out of band.
[ -n "${SECRET_SEED:-}" ] || die "SECRET_SEED is not set"

derive_b64() { printf '%s' "${SECRET_SEED}:$1" | openssl dgst -sha256 -binary | openssl base64 -A; }
derive_hex() { printf '%s' "${SECRET_SEED}:$1" | openssl dgst -sha256 -hex -r | cut -d' ' -f1; }

: "${SHARED_SECRET:=$(derive_b64 shared)}"
: "${COOKIE_SECRET:=$(derive_b64 cookie)}"
: "${IDP_CLIENT_SECRET:=$(derive_hex dex-client)}"
export SHARED_SECRET COOKIE_SECRET IDP_CLIENT_SECRET

# ------------------------------------------------------------------ ports ---
# Railway publishes one port per service; ADDRESS is what Pomerium binds. An
# empty host means dual-stack (:: plus 0.0.0.0), which the health-check prober
# reaches over IPv4 and a private peer over IPv6.
: "${PORT:=8080}"
: "${ADDRESS:=:${PORT}}"
export ADDRESS

# --------------------------------------------------------------- base URL ---
if [ -z "${POMERIUM_PUBLIC_URL:-}" ]; then
  [ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ] || die "no public domain yet - generate one for this service, then redeploy"
  POMERIUM_PUBLIC_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi
POMERIUM_PUBLIC_URL="${POMERIUM_PUBLIC_URL%/}"
export POMERIUM_PUBLIC_URL

[ -n "${AUTHENTICATE_SERVICE_URL:-}" ] || die "AUTHENTICATE_SERVICE_URL is not set"

# ------------------------------------------------------------------ policy ---
# One allow block shared by every route. Emails and domains are both lists so a
# deployer can open the gateway to a whole workspace without editing YAML.
: "${ALLOWED_EMAILS:=${ADMIN_EMAIL:-}}"
: "${ALLOWED_DOMAINS:=}"

emit_policy() {
  local indent="$1" entry
  printf '%spolicy:\n%s  - allow:\n%s      or:\n' "$indent" "$indent" "$indent"
  local wrote=0
  local IFS=','
  for entry in ${ALLOWED_EMAILS}; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    printf '%s        - email:\n%s            is: "%s"\n' "$indent" "$indent" "$entry"
    wrote=1
  done
  for entry in ${ALLOWED_DOMAINS}; do
    entry="$(printf '%s' "$entry" | tr -d '[:space:]')"
    [ -n "$entry" ] || continue
    printf '%s        - domain:\n%s            is: "%s"\n' "$indent" "$indent" "$entry"
    wrote=1
  done
  [ "$wrote" = 1 ] || die "no ALLOWED_EMAILS or ALLOWED_DOMAINS - every route would reject every user"
}

emit_route() {
  # $1 upstream URL, $2 path prefix ("" for the whole host)
  local to="$1" prefix="$2"
  printf '  - from: "%s"\n' "$POMERIUM_PUBLIC_URL"
  printf '    to: "%s"\n' "$to"
  if [ -n "$prefix" ]; then printf '    prefix: "%s"\n' "$prefix"; fi
  printf '    pass_identity_headers: true\n'
  printf '    allow_websockets: true\n'
  printf '    preserve_host_header: false\n'
  emit_policy '    '
}

render_routes() {
  : "${UPSTREAM_URL:=http://verify.railway.internal:8000}"
  {
    printf '# rendered by entrypoint.sh - edit the variables, not this file\n'
    printf 'routes:\n'
    local i url_var prefix_var url prefix
    for i in 2 3 4 5; do
      url_var="UPSTREAM_${i}_URL"; prefix_var="UPSTREAM_${i}_PREFIX"
      url="${!url_var:-}"; prefix="${!prefix_var:-}"
      [ -n "$url" ] || continue
      [ -n "$prefix" ] || die "UPSTREAM_${i}_URL needs UPSTREAM_${i}_PREFIX - two routes cannot share one host at the same path"
      emit_route "$url" "$prefix"
    done
    # the catch-all is written last: Envoy matches routes in order, so a
    # prefixed upstream above would otherwise never be reached
    emit_route "$UPSTREAM_URL" ""
  } > "$CONFIG_FILE"
}

case ",${SERVICES_VALUE}," in
  *,all,*|*,proxy,*)
    render_routes
    log "routes rendered for ${POMERIUM_PUBLIC_URL}"
    log "route count: $(grep -c '^  - from:' "$CONFIG_FILE")"
    ;;
  *)
    printf '# no routes: this service does not run the proxy\n' > "$CONFIG_FILE"
    ;;
esac

log "services=${SERVICES_VALUE} address=${ADDRESS} authenticate=${AUTHENTICATE_SERVICE_URL}"
exec /usr/local/bin/pomerium --config "$CONFIG_FILE"
