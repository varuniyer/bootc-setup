#!/usr/bin/env bash
set -euo pipefail

# Builds the latest PostgreSQL 17 release against the same fedora-bootc
# userland as the final stage, so the installed tree links cleanly there.
dnf install -y --setopt=install_weak_deps=False gcc make bison flex perl tar gzip curl zlib-devel openssl-devel systemd-devel

VERSION=$(curl -sf https://ftp.postgresql.org/pub/source/ | grep -oE 'v17\.[0-9]+' | sort -uV | tail -1)
curl -sfO "https://ftp.postgresql.org/pub/source/$VERSION/postgresql-${VERSION#v}.tar.gz"
tar xf "postgresql-${VERSION#v}.tar.gz" && cd "postgresql-${VERSION#v}"

./configure --prefix=/usr --libdir=/usr/lib64 --with-ssl=openssl --with-systemd --without-icu --without-readline \
    CFLAGS="-O2 -fstack-protector-strong -D_FORTIFY_SOURCE=3 -fPIE" LDFLAGS="-Wl,-z,relro,-z,now" LDFLAGS_EX="-pie"
make -j"$(nproc)" world-bin
make install-world-bin DESTDIR=/build
rm -rf /build/usr/include /build/usr/lib64/pgxs
