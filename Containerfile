# --------------------------------------
# Stage 1: Hugo build
# --------------------------------------
FROM ghcr.io/gohugoio/hugo:latest AS hugo
USER root
WORKDIR /src
COPY website/ .
RUN mkdir -p public
RUN hugo build --minify


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
# Stage 3: Final bootc image
# --------------------------------------
FROM quay.io/fedora/fedora-bootc:latest

# Static site
COPY --from=compress /work/public /usr/share/caddy

# System config files
COPY prepare-root.conf /usr/lib/ostree/prepare-root.conf
COPY bootc.json        /etc/bootc/bootc.json

# Caddy + httpd + postgres configs
COPY Caddyfile           /etc/caddy/Caddyfile
COPY webdav.conf         /etc/httpd/conf.d/webdav.conf
COPY postgresql.conf     /usr/share/postgres/postgresql.conf
COPY pg_hba.conf         /usr/share/postgres/pg_hba.conf
COPY bootstrap.sql       /usr/share/postgres/bootstrap.sql

# SSH config + authorized keys
COPY 30-authkeys.conf            /etc/ssh/sshd_config.d/30-authkeys.conf
COPY 40-experiments.conf         /etc/ssh/sshd_config.d/40-experiments.conf
COPY authorized_keys.root        /etc/ssh/authorized_keys.d/root
COPY authorized_keys.experiments /etc/ssh/authorized_keys.d/experiments

# Scripts and units
COPY setup.sh             /usr/libexec/setup.sh
COPY post-startup.sh      /usr/libexec/post-startup.sh
COPY post-startup.service /usr/lib/systemd/system/post-startup.service

# Single build-time mutation layer
RUN bash /usr/libexec/setup.sh
