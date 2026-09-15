FROM debian:bookworm-slim

# Pomerium publishes a distroless image, so the binary is lifted onto a base that
# has a shell, CA certificates and openssl: the entrypoint derives Pomerium's
# matched secret set and renders the route table, neither of which a Railway
# variable can express.
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates openssl tini curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=pomerium/pomerium:latest /bin/pomerium /usr/local/bin/pomerium

COPY pomerium/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN chmod +x /usr/local/bin/entrypoint.sh \
    && bash -n /usr/local/bin/entrypoint.sh \
    && command -v openssl \
    && /usr/local/bin/pomerium --version

WORKDIR /pomerium

CMD ["/usr/bin/tini", "-s", "--", "/usr/local/bin/entrypoint.sh"]
