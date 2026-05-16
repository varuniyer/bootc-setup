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

# Static site
COPY --from=compress /work/public /usr/share/caddy

# Configs
COPY Caddyfile /etc/caddy/Caddyfile
COPY httpd.conf /usr/share/webdav/httpd.conf

RUN mkdir -p /usr/share/postgres
COPY postgresql.conf /usr/share/postgres/postgresql.conf
COPY pg_hba.conf /usr/share/postgres/pg_hba.conf

# bootc tracking config
RUN mkdir -p /etc/bootc && echo '{ "image": "ghcr.io/varuniyer/bootc-setup:latest" }' > /etc/bootc/bootc.json

# Quadlets
COPY webdav.container /etc/containers/systemd/users/httpd/webdav.container
COPY postgres.container /etc/containers/systemd/users/experiments/postgres.container

# Setup scripts
COPY setup-users.sh /usr/bin/setup-users.sh
RUN chmod +x /usr/bin/setup-users.sh

COPY setup-users.service /etc/systemd/system/setup-users.service
RUN systemctl enable setup-users.service

# Enable reboot after bootc update
RUN mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.service.d

RUN cat <<EOF > /etc/systemd/system/bootc-fetch-apply-updates.service.d/override.conf
[Service]
ExecStart=
ExecStart=/usr/bin/bootc-fetch-apply-updates --reboot
EOF
