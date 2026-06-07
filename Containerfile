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
COPY prepare-root.conf      /usr/lib/ostree/prepare-root.conf
COPY bootc.json             /etc/bootc/bootc.json
COPY Caddyfile              /etc/caddy/Caddyfile
COPY chrony.conf            /usr/etc/chrony.conf
# Grouped configs
COPY postgresql/ /usr/share/postgres/

# nftables firewall (loaded by stock nftables.service)
COPY nftables.conf /etc/sysconfig/nftables.conf

# Scripts and units
COPY setup.sh             /usr/libexec/setup.sh
COPY post-startup.sh      /usr/libexec/post-startup.sh
COPY bootstrap.sh         /usr/libexec/bootstrap.sh
COPY fetch_metadata.sh    /usr/bin/fetch_metadata
COPY post-startup.service /usr/lib/systemd/system/post-startup.service

# Single build-time mutation layer
RUN bash /usr/libexec/setup.sh
