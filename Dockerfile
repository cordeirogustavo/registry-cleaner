FROM docker:29-cli

ARG TARGETARCH
ARG SUPERCRONIC_VERSION=v0.2.51
ARG SUPERCRONIC_SHA1SUM_amd64=1692066e350a88ff4d7d6474fe3c7a6c41ec5e89
ARG SUPERCRONIC_SHA1SUM_arm64=9d4c2000493215a1898502b2fc2dada3e8ea8c7a

RUN apk add --no-cache bash curl jq tzdata

RUN set -eu; \
    eval "checksum=\$SUPERCRONIC_SHA1SUM_${TARGETARCH}"; \
    curl -fsSLo /usr/local/bin/supercronic \
      "https://github.com/aptible/supercronic/releases/download/${SUPERCRONIC_VERSION}/supercronic-linux-${TARGETARCH}"; \
    echo "${checksum}  /usr/local/bin/supercronic" | sha1sum -c -; \
    chmod +x /usr/local/bin/supercronic

COPY --chmod=755 prune-registry.sh /usr/local/bin/prune-registry
COPY --chmod=755 entrypoint.sh /usr/local/bin/entrypoint

ENTRYPOINT ["/usr/local/bin/entrypoint"]
