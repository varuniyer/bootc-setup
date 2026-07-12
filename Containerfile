# Stage 1: Hugo build
FROM ghcr.io/gohugoio/hugo:latest AS hugo
WORKDIR /src
COPY --chown=hugo:hugo website/ .
RUN mkdir -p public && hugo build --minify


# Stage 2: Compression
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


# Stage 3: PostgreSQL source build
FROM quay.io/fedora/fedora-bootc:latest AS pgbuild
COPY postgresql/build.sh /build.sh
RUN bash /build.sh


# Stage 4: Final bootc image
FROM quay.io/fedora/fedora-bootc:latest

# Static site
COPY --from=compress /work/public /usr/share/website
# Binaries from official images (relabeled by setup.sh)
COPY --from=docker.io/tailscale/tailscale:latest /usr/local/bin/tailscale /usr/local/bin/tailscaled /usr/bin/
COPY --from=docker.io/library/caddy:latest       /usr/bin/caddy           /usr/bin/caddy
COPY --from=docker.io/rclone/rclone:latest       /usr/local/bin/rclone    /usr/bin/rclone
COPY --from=pgbuild                              /build/usr               /usr

# Config files
COPY fstab                  /usr/etc/fstab
COPY prepare-root.conf      /usr/lib/ostree/prepare-root.conf
COPY bootc.json             /etc/bootc/bootc.json
COPY caddy/Caddyfile        /etc/caddy/Caddyfile
COPY journald.conf          /etc/systemd/journald.conf
COPY nftables.conf          /etc/sysconfig/nftables.conf
COPY 99-synproxy.conf       /usr/lib/sysctl.d/99-synproxy.conf
COPY postgresql/tmpfiles.conf /usr/lib/tmpfiles.d/postgres.conf
COPY caddy/tmpfiles.conf    /usr/lib/tmpfiles.d/caddy.conf
COPY postgresql/postgresql.conf postgresql/pg_hba.conf postgresql/bootstrap.sql /usr/share/postgres/

ENV PATH="/opt/scripts:${PATH}"
COPY setup.sh post-startup-root.sh fetch_metadata.sh tailscale/post-startup-tailscale.sh postgresql/post-startup-postgresql.sh postgresql/bootstrap.sh /opt/scripts/
COPY post-startup-root.service rclone-webdav.service tailscale/post-startup-tailscale.service tailscale/tailscaled.service postgresql/post-startup-postgresql.service postgresql/postgresql.service caddy/caddy.service /usr/lib/systemd/system/

# Single build-time mutation layer
RUN chmod +x /opt/scripts/* && setup.sh
