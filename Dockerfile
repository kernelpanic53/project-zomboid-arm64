# syntax=docker/dockerfile:1.7

ARG DEBIAN_IMAGE=arm64v8/debian:trixie-slim

# -----------------------------------------------------------------------------
# Box64: ARM64 userspace emulator for the x86_64 Project Zomboid server/JRE.
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS box64-builder
ARG TARGETARCH

ARG BOX64_VERSION=0.4.4
ARG BOX64_SHA256=99c6de4f509e46ab1de15df740d0e0ea338a7790efa3f67510dfbb975cc24029

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && test "${TARGETARCH:-$(dpkg --print-architecture)}" = arm64 \
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
        -DBOX32=ON \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr/local \
        -DNOGIT=1 \
    && cmake --build build --parallel "$(nproc)" \
    && DESTDIR=/box64-root cmake --install build \
    && install -D -m 0644 \
        source/LICENSE \
        /box64-root/usr/share/licenses/box64/LICENSE

# -----------------------------------------------------------------------------
# x86_64 SteamCMD, executed through Box64. Seed the latest Valve packages from
# the media feed because the bootstrapper's client-download hostname currently
# has a broken Akamai DNS target. SteamCMD's own updater is disabled in
# steam.cfg; rebuilds refresh these verified packages from Valve's manifest.
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS steamcmd
ARG TARGETARCH

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && test "${TARGETARCH:-$(dpkg --print-architecture)}" = arm64 \
    && apt-get install -y --no-install-recommends ca-certificates curl python3 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/steamcmd

RUN curl --fail --location --show-error --silent --retry 3 \
        https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz \
        --output steamcmd.tar.gz \
    && mkdir -p /steamcmd-root/opt/steamcmd \
    && tar --extract --gzip --file steamcmd.tar.gz --directory /steamcmd-root/opt/steamcmd \
    && chmod 0755 /steamcmd-root/opt/steamcmd/steamcmd.sh /steamcmd-root/opt/steamcmd/linux32/steamcmd \
    && rm steamcmd.tar.gz

COPY scripts/bootstrap-steamcmd.py /usr/local/bin/bootstrap-steamcmd.py
RUN python3 /usr/local/bin/bootstrap-steamcmd.py \
    && chmod 0755 /steamcmd-root/opt/steamcmd/steamcmd.sh /steamcmd-root/opt/steamcmd/linux64/steamcmd

# -----------------------------------------------------------------------------
# x86_64 Zulu Java 25 patch runtime. It is downloaded as data during the
# ARM64 build and executed through Box64 only when JAVA_RUNTIME=zulu.
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS zulu-jre
ARG ZULU_JRE_VERSION=25.0.5

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl jq \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /java-root/opt/zulu-jre

RUN metadata="$(curl --fail --location --show-error --silent --retry 3 \
        "https://api.azul.com/metadata/v1/zulu/packages/?java_version=${ZULU_JRE_VERSION}&os=linux&arch=x64&archive_type=tar.gz&java_package_type=jre&release_status=ga&availability_types=CA&include_fields=sha256_hash")" \
    && url="$(jq -er '.[0].download_url' <<< "$metadata")" \
    && sha256="$(jq -er '.[0].sha256_hash' <<< "$metadata")" \
    && curl --fail --location --show-error --silent --retry 3 "$url" --output /tmp/zulu-jre.tar.gz \
    && echo "${sha256}  /tmp/zulu-jre.tar.gz" | sha256sum --check --strict \
    && tar --extract --gzip --file /tmp/zulu-jre.tar.gz --strip-components=1 --directory /java-root/opt/zulu-jre \
    && test -x /java-root/opt/zulu-jre/bin/java \
    && rm -f /tmp/zulu-jre.tar.gz

# -----------------------------------------------------------------------------
# Final ARM64 image.
# -----------------------------------------------------------------------------
FROM ${DEBIAN_IMAGE} AS runtime

ARG PUID=1000
ARG PGID=1000
ARG TARGETARCH

LABEL org.opencontainers.image.title="Project Zomboid dedicated server for ARM64" \
      org.opencontainers.image.description="Project Zomboid dedicated server for ARM64 Kubernetes using SteamCMD and Box64" \
      org.opencontainers.image.source="https://github.com/kernelpanic53/project-zomboid-arm64" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/pz \
    PZ_SERVER_DIR=/opt/zomboid \
    PZ_CONFIG_DIR=/config \
    STEAMCMD_DIR=/opt/steamcmd \
    BOX64_LOG=0 \
    BOX64_DYNACACHE=1 \
    BOX64_DYNACACHE_FOLDER=/config/box64-dynacache \
    BOX64_DYNACACHE_LIMIT=2048 \
    BOX64_DYNAREC=1 \
    BOX64_DYNAREC_BIGBLOCK=0 \
    BOX64_DYNAREC_BLEEDING_EDGE=0 \
    BOX64_DYNAREC_BB_LOOP=1 \
    BOX64_DYNAREC_FORWARD=1 \
    BOX64_DYNAREC_STRONGMEM=3 \
    BOX64_DYNAREC_SAFEFLAGS=2 \
    BOX64_DYNAREC_ALIGNED_ATOMICS=1 \
    BOX64_JVM=0 \
    BOX64_SSE42=0 \
    BOX64_MAXCPU=4 \
    JAVA_RUNTIME=bundled \
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

COPY --chmod=0755 scripts/security-updates.sh /usr/local/bin/security-updates.sh
RUN apt-get update \
    && test "${TARGETARCH:-$(dpkg --print-architecture)}" = arm64 \
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
        procps \
        tini \
        zlib1g \
    && /usr/local/bin/security-updates.sh \
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
        /config/box64-dynacache \
        /home/pz \
        /tmp/pz \
    && chown -R pz:pz \
        /opt/zomboid \
        /config \
        /home/pz \
        /tmp/pz \
    && rm -rf /var/lib/apt/lists/*

COPY --from=box64-builder /box64-root/ /
COPY --from=steamcmd /steamcmd-root/ /
COPY --from=zulu-jre /java-root/ /

# The JRE is downloaded as root. Keep it traversable and executable for the
# non-root UID configured by Kubernetes, which may differ from the image user.
RUN chmod -R a+rX /opt/zulu-jre \
    && chmod a+x /opt/zulu-jre/bin/java /opt/zulu-jre/lib/jspawnhelper

COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

# Project Zomboid's pzexe launcher expects to execute "java" by name.
# The bundled Java runtime is x86_64, so route the command through Box64.
RUN cat > /usr/local/bin/java <<'EOF'
#!/bin/sh
set -eu

SERVER_DIR="${PZ_SERVER_DIR:-/opt/zomboid}"
if [ "${JAVA_RUNTIME:-bundled}" = "zulu" ]; then
    JAVA_BIN="/opt/zulu-jre/bin/java"
else
    JAVA_BIN="${SERVER_DIR}/jre64/bin/java"
fi

if [ ! -x "$JAVA_BIN" ]; then
    echo "ERROR: selected Java runtime not found at $JAVA_BIN" >&2
    exit 1
fi

exec /usr/local/bin/box64 "$JAVA_BIN" "$@"
EOF

RUN chmod 0755 /usr/local/bin/java

USER pz:pz

RUN test -f /opt/zulu-jre/bin/java \
    && test -x /opt/zulu-jre/bin/java

WORKDIR /opt/zomboid

VOLUME ["/opt/zomboid", "/config"]

EXPOSE 16261-16262/udp 8766-8767/udp 27015/tcp

STOPSIGNAL SIGTERM

HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=5 \
    CMD ["/usr/local/bin/healthcheck.sh"]

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
