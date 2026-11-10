FROM ghcr.io/gohugoio/hugo:latest AS hugo
WORKDIR /src
COPY --chown=hugo:hugo website/ .
RUN hugo build --minify && mv public/publications/publications.tex /src/


FROM docker.io/library/alpine:latest AS compress

RUN apk add --no-cache gzip brotli

WORKDIR /work
COPY --from=hugo /src/public ./public

RUN find public -type f \( -name '*.html' -o -name '*.xml' -o -name '*.css' -o -name '*.js' \) \
    -exec gzip --best --keep {} \; -exec brotli --best --keep {} \;


FROM quay.io/fedora/fedora-bootc:latest AS base
FROM base AS postgresql-build
COPY postgresql/build.sh /build.sh
RUN bash /build.sh


FROM quay.io/fedora/fedora:latest AS cv
RUN dnf install -y texlive-luahbtex texlive-luaotfload texlive-latex texlive-fontspec texlive-preprint texlive-titlesec texlive-graphics texlive-enumitem texlive-hyperref texlive-babel texlive-babel-english texlive-ulem texlive-sourceserif texlive-amsfonts
WORKDIR /cv
COPY cv/CV.tex .
COPY --from=hugo /src/publications.tex .
RUN lualatex -interaction=nonstopmode -halt-on-error CV.tex && lualatex -interaction=nonstopmode -halt-on-error CV.tex


FROM base

COPY --chown=0:0 --from=compress /work/public /usr/share/website
COPY --chown=0:0 --from=cv /cv/CV.pdf /usr/share/website/CV.pdf
COPY --chown=0:0 --from=docker.io/tailscale/tailscale:latest /usr/local/bin/tailscale /usr/local/bin/tailscaled /usr/bin/
COPY --chown=0:0 --from=docker.io/library/caddy:latest       /usr/bin/caddy           /usr/bin/caddy
COPY --chown=0:0 --from=docker.io/rclone/rclone:latest       /usr/local/bin/rclone    /usr/bin/rclone
COPY --chown=0:0 --from=postgresql-build                     /build/usr               /usr

COPY fstab                  /etc/fstab
COPY prepare-root.conf      /usr/lib/ostree/prepare-root.conf
COPY caddy/Caddyfile        /etc/caddy/Caddyfile
COPY journald.conf          /etc/systemd/journald.conf
COPY hardening.conf         /usr/lib/systemd/hardening.conf
COPY tmpfiles.d/root.conf   /etc/tmpfiles.d/root.conf
COPY nftables.conf          /etc/sysconfig/nftables.conf
COPY postgresql/postgresql-dirs.conf /usr/lib/tmpfiles.d/postgresql-dirs.conf
COPY caddy/caddy-dirs.conf  /usr/lib/tmpfiles.d/caddy-dirs.conf
COPY caddy/caddy_local.cil  /usr/share/selinux/packages/caddy_local.cil
COPY containers/policy.json /etc/containers/policy.json
COPY containers/bootc-setup.yaml /etc/containers/registries.d/bootc-setup.yaml
COPY containers/sigpolicy.toml /usr/lib/bootc/install/sigpolicy.toml
COPY postgresql/postgresql.conf postgresql/pg_hba.conf postgresql/bootstrap.sql /usr/share/boot-postgresql/

ENV PATH="/opt/scripts:${PATH}"
COPY setup.sh boot-root.sh fetch_metadata.sh tailscale/boot-tailscale.sh postgresql/boot-postgresql.sh postgresql/bootstrap.sh /opt/scripts/
COPY boot-root.service rclone-webdav.service tailscale/boot-tailscale.service tailscale/tailscaled.service postgresql/boot-postgresql.service postgresql/postgresql.service caddy/caddy.service /usr/lib/systemd/system/

RUN chmod +x /opt/scripts/* && setup.sh
