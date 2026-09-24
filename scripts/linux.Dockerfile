# Linux test image for scripts/test-linux.sh: Ubuntu with clang (Odin's
# linker) and a pinned Odin release. Keep ODIN_VERSION in step with the
# compiler used on the development machine (`odin version`).
FROM ubuntu:24.04
ARG ODIN_VERSION=dev-2026-09
ARG ODIN_ARCH=arm64
RUN apt-get update \
 && apt-get install -y --no-install-recommends clang curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL "https://github.com/odin-lang/Odin/releases/download/${ODIN_VERSION}/odin-linux-${ODIN_ARCH}-${ODIN_VERSION}.tar.gz" -o /tmp/odin.tgz \
 && mkdir -p /opt/odin \
 && tar -xzf /tmp/odin.tgz -C /opt/odin --strip-components=1 \
 && rm /tmp/odin.tgz
ENV PATH=/opt/odin:$PATH
WORKDIR /src
