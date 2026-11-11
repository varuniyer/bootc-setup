FROM quay.io/fedora/fedora-bootc:latest AS base
# The PostgreSQL stage builds on the final stage's base, so the installed tree links against the libraries the image ships.
FROM base AS postgresql-build
COPY postgresql/build.sh /build.sh
RUN bash /build.sh


# The website repo's publish workflow builds the site and CV into its `site` branch.
FROM base AS site
ARG WEBSITE_REPO
RUN mkdir /site && curl -sSf --retry 3 --retry-all-errors https://codeload.github.com/$WEBSITE_REPO/tar.gz/refs/heads/site | tar -xz -C /site --strip-components=1


FROM base

COPY --chown=0:0 --from=site /site /usr/share/site
COPY --chown=0:0 --from=docker.io/tailscale/tailscale:latest /usr/local/bin/tailscale /usr/local/bin/tailscaled /usr/bin/
COPY --chown=0:0 --from=docker.io/library/caddy:latest       /usr/bin/caddy           /usr/bin/caddy
COPY --chown=0:0 --from=docker.io/rclone/rclone:latest       /usr/local/bin/rclone    /usr/bin/rclone
COPY --chown=0:0 --from=postgresql-build                     /build/usr               /usr

COPY fstab                  /etc/fstab
COPY prepare-root.conf      /usr/lib/ostree/prepare-root.conf
COPY caddy/Caddyfile        /etc/caddy/Caddyfile
COPY journald.conf          /etc/systemd/journald.conf
COPY sandbox.conf           /usr/lib/systemd/sandbox.conf
COPY postgresql/run-as-postgres.conf /usr/lib/systemd/run-as-postgres.conf
COPY postgresql/pgdata.conf /usr/lib/systemd/pgdata.conf
COPY tmpfiles.d/root.conf   /etc/tmpfiles.d/root.conf
COPY nftables.conf          /etc/sysconfig/nftables.conf
COPY postgresql/postgresql-dirs.conf /usr/lib/tmpfiles.d/postgresql-dirs.conf
COPY caddy/caddy-dirs.conf  /usr/lib/tmpfiles.d/caddy-dirs.conf
COPY caddy/caddy_local.cil  /usr/share/selinux/packages/caddy_local.cil
COPY containers/policy.json /etc/containers/policy.json
COPY containers/bootc-setup.yaml /etc/containers/registries.d/bootc-setup.yaml
COPY containers/sigpolicy.toml /usr/lib/bootc/install/sigpolicy.toml
COPY postgresql/postgresql.conf postgresql/pg_hba.conf postgresql/bootstrap.sql /usr/share/boot-postgresql/

COPY setup.sh boot-root.sh fetch_metadata.sh tailscale/boot-tailscale.sh postgresql/boot-postgresql.sh postgresql/bootstrap.sh /opt/scripts/
COPY boot-root.service rclone-webdav.service tailscale/boot-tailscale.service tailscale/tailscaled.service postgresql/boot-postgresql.service postgresql/postgresql.service caddy/caddy.service /usr/lib/systemd/system/
COPY boot-root-capabilities.conf /usr/lib/systemd/system/boot-root.service.d/zz-capabilities.conf
COPY caddy/caddy-capabilities.conf /usr/lib/systemd/system/caddy.service.d/zz-capabilities.conf

RUN chmod +x /opt/scripts/* && /opt/scripts/setup.sh
