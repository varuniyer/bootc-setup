# --------------------------------------
# Stage 1: Hugo build
# --------------------------------------
FROM ghcr.io/gohugoio/hugo:latest AS hugo

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
    -exec gzip --keep --best {} \; \
    -exec brotli --keep --best {} \;

# --------------------------------------
# Stage 3: Final bootc image
# --------------------------------------
FROM quay.io/fedora/fedora-bootc:latest

COPY --from=compress /work/public /usr/share/caddy

COPY Caddyfile /etc/caddy/Caddyfile
COPY httpd.conf /usr/share/webdav/httpd.conf

RUN mkdir -p /usr/share/postgres
COPY postgresql.conf /usr/share/postgres/postgresql.conf
COPY pg_hba.conf /usr/share/postgres/pg_hba.conf

COPY webdav.container /etc/containers/systemd/users/httpd/webdav.container
COPY postgres.container /etc/containers/systemd/users/experiments/postgres.container

COPY setup.sh /usr/libexec/setup.sh
RUN chmod +x /usr/libexec/setup.sh && /usr/libexec/setup.sh
