# syntax=docker/dockerfile:1.7
#
# EXPERIMENTAL FEX image for Project Zomboid Build 42 on ARM64.
# Build for linux/arm64 with Docker Buildx. The x86-64 rootfs is built from
# the official Ubuntu image rather than downloaded from an unverified file host.

ARG ARM64_IMAGE=arm64v8/ubuntu:22.04
ARG X86_64_ROOTFS_IMAGE=amd64/ubuntu:25.04

FROM ${ARM64_IMAGE} AS fex-builder
ARG FEX_COMMIT=a08a6ce
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        clang \
        cmake \
        git \
        lld \
        llvm \
        ninja-build \
        pkg-config \
        python3 \
        python3-setuptools \
        squashfs-tools \
        squashfuse \
        libssl-dev \
        libsdl2-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN git clone --recurse-submodules https://github.com/FEX-Emu/FEX.git \
    && cd FEX \
    && git checkout "${FEX_COMMIT}" \
    && git submodule update --init --recursive \
    && cmake -S . -B Build -G Ninja \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_BUILD_TYPE=Release \
        -DUSE_LINKER=lld \
        -DENABLE_LTO=True \
        -DBUILD_TESTING=False \
        -DENABLE_ASSERTIONS=False \
    && cmake --build Build --parallel "$(nproc)" \
    && DESTDIR=/fex-root cmake --install Build

# A real x86-64 Ubuntu 25.04 root filesystem for FEX (EOL; experimental only). Docker Buildx may use QEMU
# to run this stage; no x86-64 binaries are executed by the ARM64 final stage.
FROM --platform=linux/amd64 ${X86_64_ROOTFS_IMAGE} AS fex-rootfs
ENV DEBIAN_FRONTEND=noninteractive
RUN sed -i -E \
        -e "s|http://archive.ubuntu.com/ubuntu|http://old-releases.ubuntu.com/ubuntu|g" \
        -e "s|http://security.ubuntu.com/ubuntu|http://old-releases.ubuntu.com/ubuntu|g" \
        /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        libatomic1 \
        libgcc-s1 \
        libice6 \
        libsm6 \
        libsdl2-2.0-0 \
        libstdc++6 \
        libx11-6 \
        libxext6 \
        libxrender1 \
        libxtst6 \
        libsdl3-0 \
        zlib1g \
    && rm -rf /var/lib/apt/lists/*

FROM ${ARM64_IMAGE} AS depotdownloader
ARG DEPOTDOWNLOADER_VERSION=3.4.0
ARG DEPOTDOWNLOADER_SHA256=d9fb612ccebc1db8eeea3b4045d2221ec70431381393ce908fb72f01d4f9c812
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl unzip \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /tmp/depotdownloader
RUN curl --fail --location --show-error --silent --retry 3 \
        "https://github.com/SteamRE/DepotDownloader/releases/download/DepotDownloader_${DEPOTDOWNLOADER_VERSION}/DepotDownloader-linux-arm64.zip" \
        --output depotdownloader.zip \
    && echo "${DEPOTDOWNLOADER_SHA256}  depotdownloader.zip" | sha256sum --check --strict \
    && mkdir -p /depot-root/opt/depotdownloader \
    && unzip -q depotdownloader.zip -d /depot-root/opt/depotdownloader \
    && chmod 0755 /depot-root/opt/depotdownloader/DepotDownloader

FROM ${ARM64_IMAGE}
ARG PUID=1000
ARG PGID=1000
LABEL org.opencontainers.image.title="Experimental Project Zomboid dedicated server for ARM64 (FEX)" \
      org.opencontainers.image.description="Experimental Project Zomboid Build 42 server for ARM64 Kubernetes using FEX and native ARM64 DepotDownloader" \
      org.opencontainers.image.source="https://github.com/kernelpanic53/project-zomboid-arm64" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/pz \
    PZ_SERVER_DIR=/opt/zomboid \
    PZ_CONFIG_DIR=/config \
    DEPOTDOWNLOADER_DIR=/opt/depotdownloader \
    FEX_ROOTFS_NAME=Ubuntu_25_04 \
    FEX_MULTIBLOCK=0 \
    SERVER_NAME=servertest \
    SERVER_PUBLIC=false \
    SERVER_PORT=16261 \
    SERVER_UDP_PORT=16262 \
    STEAM_PORT_1=8766 \
    STEAM_PORT_2=8767 \
    RCON_PORT=27015 \
    SERVER_BRANCH=public \
    UPDATE_ON_START=true \
    MEMORY=4G \
    FEX_JIT_MODE=interpreter

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
        libsdl2-2.0-0 \
        libstdc++6 \
        libx11-6 \
        libxext6 \
        libxrender1 \
        libxtst6 \
        netcat-openbsd \
        procps \
        tini \
        zlib1g \
    && groupadd --gid "${PGID}" pz \
    && useradd --uid "${PUID}" --gid "${PGID}" --create-home --home-dir /home/pz --shell /bin/bash pz \
    && mkdir -p /opt/zomboid /config /home/pz /tmp/pz \
        /home/pz/.fex-emu/RootFS/Ubuntu_25_04 \
    && chown -R pz:pz /opt/zomboid /config /home/pz /tmp/pz \
    && rm -rf /var/lib/apt/lists/*

COPY --from=fex-builder /fex-root/usr/ /usr/
COPY --from=fex-rootfs / /home/pz/.fex-emu/RootFS/Ubuntu_25_04/
COPY --from=depotdownloader /depot-root/ /
COPY --chmod=0644 docker/fex/Config.json /home/pz/.fex-emu/Config.json
COPY --chmod=0755 scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --chmod=0755 scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

RUN chown -R pz:pz /home/pz/.fex-emu \
    && chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/healthcheck.sh

USER pz:pz
WORKDIR /opt/zomboid
VOLUME ["/opt/zomboid", "/config"]
EXPOSE 16261-16262/udp 8766-8767/udp 27015/tcp
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=30s --timeout=5s --start-period=10m --retries=5 \
    CMD ["/usr/local/bin/healthcheck.sh"]
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/entrypoint.sh"]
