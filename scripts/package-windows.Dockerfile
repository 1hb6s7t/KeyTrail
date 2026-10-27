# Toolchain only. Build without sending source/user data as Docker context:
# docker build -t keytrail-windows-builder:1.2 - < scripts/package-windows.Dockerfile
FROM rust:1-bookworm
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends gcc-mingw-w64-x86-64 && rm -rf /var/lib/apt/lists/* && rustup target add x86_64-pc-windows-gnu
ENV CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc
ENV CC_x86_64_pc_windows_gnu=x86_64-w64-mingw32-gcc
WORKDIR /src
