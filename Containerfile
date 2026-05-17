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
FROM ghcr.io/secureblue/securecore-main-hardened:latest

# Static site
COPY --from=compress /work/public /usr/share/caddy

# Configs
COPY Caddyfile /etc/caddy/Caddyfile
COPY httpd.conf /usr/share/webdav/httpd.conf

RUN mkdir -p /usr/share/postgres
COPY postgresql.conf /usr/share/postgres/postgresql.conf
COPY pg_hba.conf /usr/share/postgres/pg_hba.conf

# bootc tracking
RUN mkdir -p /etc/bootc
RUN echo '{ "image": "ghcr.io/varuniyer/bootc-setup:latest" }' > /etc/bootc/bootc.json

# Quadlets
COPY webdav.container /etc/containers/systemd/users/httpd/webdav.container
COPY postgres.container /etc/containers/systemd/users/experiments/postgres.container

# Cosign material for signature verification
COPY cosign.pub /etc/containers/keys/cosign.pub
RUN printf 'docker:\n  ghcr.io:\n    use-sigstore-attachments: true\n' > /etc/containers/registries.d/ghcr.yaml

# Build-time setup (file edits via ujust)
COPY setup-build.sh /usr/libexec/setup-build.sh
RUN chmod +x /usr/libexec/setup-build.sh && /usr/libexec/setup-build.sh

# First-boot setup script
COPY setup-firstboot.sh /usr/libexec/setup-firstboot.sh
RUN chmod +x /usr/libexec/setup-firstboot.sh

# Systemd bootstrap service
COPY setup.service /etc/systemd/system/setup.service
RUN systemctl enable setup.service
RUN systemctl enable bootc-fetch-apply-updates.timer

# Reboot on update
RUN mkdir -p /etc/systemd/system/bootc-fetch-apply-updates.service.d
RUN printf "[Service]\nExecStart=\nExecStart=/usr/bin/bootc-fetch-apply-updates --reboot\n" \
    > /etc/systemd/system/bootc-fetch-apply-updates.service.d/override.conf
