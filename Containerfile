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

# Configs
COPY Caddyfile /etc/caddy/Caddyfile
COPY webdav.conf /etc/httpd/conf.d/webdav.conf
COPY postgresql.conf /usr/share/postgres/postgresql.conf
COPY pg_hba.conf /usr/share/postgres/pg_hba.conf

# Scripts and units
COPY setup.sh /usr/libexec/setup.sh
COPY post-startup.sh /usr/libexec/post-startup.sh
COPY post-startup.service /etc/systemd/system/post-startup.service

# Single build-time mutation layer
RUN bash /usr/libexec/setup.sh
