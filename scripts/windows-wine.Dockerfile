# A disposable compatibility test environment, not a Windows kernel/VM.
# Build with --platform linux/amd64; Docker's CPU emulation is used on ARM hosts.
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    wine64 xvfb xauth ca-certificates python3 procps \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 fixture
USER 10001:10001
ENV WINEARCH=win64 WINEPREFIX=/tmp/keytrail-wine WINEDEBUG=-all
WORKDIR /tmp
