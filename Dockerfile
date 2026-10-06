# syntax=docker/dockerfile:1.7

ARG DEBIAN_IMAGE=arm64v8/debian:trixie-slim

# -----------------------------------------------------------------------------
# Box64: ARM64 userspace emulator for the x86_64 Project Zomboid server/JRE.
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS box64-builder

ARG BOX64_VERSION=0.4.4
ARG BOX64_SHA256=99c6de4f509e46ab1de15df740d0e0ea338a7790efa3f67510dfbb975cc24029

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        curl \
        python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/box64

RUN curl --fail --location --show-error --silent --retry 3 \
        "https://github.com/ptitSeb/box64/archive/refs/tags/v${BOX64_VERSION}.tar.gz" \
        --output box64.tar.gz \
    && echo "${BOX64_SHA256}  box64.tar.gz" | sha256sum --check --strict \
    && mkdir source build \
    && tar --extract --gzip \
        --file box64.tar.gz \
        --strip-components=1 \
        --directory source \
    && cmake \
        -S source \
        -B build \
        -DARM_DYNAREC=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DNOGIT=1 \
    && cmake --build build --parallel "$(nproc)" \
    && DESTDIR=/box64-root cmake --install build \
    && install -D -m 0644 \
        source/LICENSE \
        /box64-root/usr/share/licenses/box64/LICENSE

# -----------------------------------------------------------------------------
# Native ARM64 DepotDownloader.
#
# It downloads the official Linux x86_64 Project Zomboid dedicated-server
# depot without requiring x86 SteamCMD in the ARM64 image.
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS depotdownloader

ARG DEPOTDOWNLOADER_VERSION=3.4.0
ARG DEPOTDOWNLOADER_SHA256=d9fb612ccebc1db8eeea3b4045d2221ec70431381393ce908fb72f01d4f9c812

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        unzip \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/depotdownloader

RUN curl --fail --location --show-error --silent --retry 3 \
        "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOTDOWNLOADER_VERSION}/DepotDownloader-linux-arm64.zip" \
        --output depotdownloader.zip \
    && echo "${DEPOTDOWNLOADER_SHA256}  depotdownloader.zip" | sha256sum --check --strict \
    && mkdir -p /depot-root/opt/depotdownloader \
    && unzip -q depotdownloader.zip -d /depot-root/opt/depotdownloader \
    && chmod 0755 /depot-root/opt/depotdownloader/DepotDownloader

# -----------------------------------------------------------------------------
# Final ARM64 image.
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE}

ARG PUID=1000
ARG PGID=1000

LABEL org.opencontainers.image.title="Project Zomboid dedicated server for ARM64" \
      org.opencontainers.image.description="Project Zomboid Build 42 dedicated server for ARM64 Kubernetes using native DepotDownloader and Box64" \
      org.opencontainers.image.source="https://github.com/kernelpanic53/project-zomboid-arm64" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/pz \
    PZ_SERVER_DIR=/opt/zomboid \
    PZ_CONFIG_DIR=/config \
    DEPOTDOWNLOADER_DIR=/opt/depotdownloader \
    BOX64_LOG=0 \
    BOX64_DYNAREC=1 \
    BOX64_DYNAREC_BIGBLOCK=0 \
    BOX64_DYNAREC_BLEEDING_EDGE=0 \
    BOX64_DYNAREC_BB_LOOP=1 \
    BOX64_DYNAREC_FORWARD=1 \
    BOX64_DYNAREC_STRONGMEM=1 \
    BOX64_DYNAREC_SAFEFLAGS=2 \
    BOX64_JVM=1 \
    SERVER_NAME=servertest \
    SERVER_PUBLIC=false \
    SERVER_PORT=16261 \
    SERVER_UDP_PORT=16262 \
    STEAM_PORT_1=8766 \
    STEAM_PORT_2=8767 \
    RCON_PORT=27015 \
    SERVER_BRANCH=public \
    UPDATE_ON_START=true \
    MEMORY=4G

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        libatomic1 \
        libgcc-s1 \
        libice6 \
        libsm6 \
        libstdc++6 \
        libx11-6 \
        libxext6 \
        netcat-openbsd \
        tini \
        zlib1g \
    && groupadd --gid "${PGID}" pz \
    && useradd \
        --uid "${PUID}" \
        --gid "${PGID}" \
        --create-home \
        --home-dir /home/pz \
        --shell /bin/bash \
        pz \
    && mkdir -p \
        /opt/zomboid \
        /config \
        /home/pz \
        /tmp/pz \
    && chown -R pz:pz \
        /opt/zomboid \
        /config \
        /home/pz \
        /tmp/pz \
    && rm -rf /var/lib/apt/lists/*

COPY --from=box64-builder /box64-root/ /
COPY --from=depotdownloader /depot-root/ /

COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

# Project Zomboid's pzexe launcher expects to execute "java" by name.
# The bundled Java runtime is x86_64, so route the command through Box64.
RUN cat > /usr/local/bin/java <<'EOF'
#!/bin/sh
set -eu

SERVER_DIR="${PZ_SERVER_DIR:-/opt/zomboid}"
JAVA_BIN="${SERVER_DIR}/jre64/bin/java"

if [ ! -x "$JAVA_BIN" ]; then
    echo "ERROR: bundled Java runtime not found at $JAVA_BIN" >&2
    exit 1
fi

exec /usr/local/bin/box64 "$JAVA_BIN" "$@"
EOF

RUN chmod 0755 /usr/local/bin/java

USER pz:pz

WORKDIR /opt/zomboid

VOLUME ["/opt/zomboid", "/config"]

EXPOSE 16261-16262/udp 8766-8767/udp 27015/tcp

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=5 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
