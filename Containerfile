# --------------------------------------
# Stage 1: Hugo build
# --------------------------------------
FROM ghcr.io/gohugoio/hugo:latest AS hugo
WORKDIR /src
COPY --chown=hugo:hugo website/ .
RUN mkdir -p public && hugo build --minify


# --------------------------------------
# Stage 2: Compression
# --------------------------------------
FROM docker.io/library/alpine:latest AS compress

RUN apk add --no-cache gzip brotli findutils

WORKDIR /work
COPY --from=hugo /src/public ./public

RUN find public -type f \( \
      -name '*.html' -o \
      -name '*.xml' -o \
      -name '*.css' -o \
      -name '*.js' \
    \) \
    -exec gzip --best --keep {} \; \
    -exec brotli --best --keep {} \;


# --------------------------------------
# Stage 3: Caddy with layer4 + webdav plugins
# --------------------------------------
FROM docker.io/library/caddy:builder AS caddy-build
RUN xcaddy build --with github.com/mholt/caddy-l4 --with github.com/mholt/caddy-webdav


# --------------------------------------
# Stage 4: Final bootc image
# --------------------------------------
FROM quay.io/fedora/fedora-bootc:latest

# Static site
COPY --from=compress    /work/public      /usr/share/caddy
# Custom caddy binary (moved into place by setup.sh)
COPY --from=caddy-build /usr/bin/caddy    /tmp/caddy.custom

# Standalone config files
COPY fstab                  /usr/etc/fstab
COPY prepare-root.conf      /usr/lib/ostree/prepare-root.conf
COPY bootc.json             /etc/bootc/bootc.json
COPY Caddyfile              /etc/caddy/Caddyfile
COPY journald.conf          /etc/systemd/journald.conf
COPY nftables.conf          /etc/sysconfig/nftables.conf
COPY 99-synproxy.conf       /usr/lib/sysctl.d/99-synproxy.conf
# Grouped configs
COPY postgresql/ /usr/share/postgres/

ENV PATH="/opt/scripts:${PATH}"
COPY setup.sh post-startup-root.sh post-startup-postgresql.sh bootstrap.sh fetch_metadata.sh /opt/scripts/
COPY --chmod=0644 post-startup-root.service post-startup-postgresql.service /usr/lib/systemd/system/
COPY --chmod=0644 caddy.override.conf       /usr/lib/systemd/system/caddy.service.d/override.conf
COPY --chmod=0644 postgresql.override.conf  /usr/lib/systemd/system/postgresql.service.d/override.conf

# Single build-time mutation layer
RUN chmod +x /opt/scripts/* && setup.sh
