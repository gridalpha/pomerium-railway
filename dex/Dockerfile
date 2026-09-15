FROM ghcr.io/dexidp/dex:v2.45.1-alpine

USER root

# htpasswd is the bcrypt generator; no Railway variable can hash a password, and
# Dex only accepts a hash.
RUN apk add --no-cache apache2-utils openssl

COPY dex/entrypoint.sh /usr/local/bin/dex-entrypoint.sh

RUN chmod 0755 /usr/local/bin/dex-entrypoint.sh \
    && sh -n /usr/local/bin/dex-entrypoint.sh \
    && command -v htpasswd \
    && dex version

USER dex:dex

ENTRYPOINT ["/usr/local/bin/dex-entrypoint.sh"]
