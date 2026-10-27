# Build from repository root: docker build -f deploy/Dockerfile -t keytrail-private:1.2 .
FROM rust:1-bookworm AS build
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev pkg-config && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY rust/Cargo.toml rust/Cargo.lock ./rust/
COPY rust/keytrail-core ./rust/keytrail-core
COPY rust/keytrail-server ./rust/keytrail-server
COPY rust/keytrail-windows ./rust/keytrail-windows
COPY web ./web
RUN cargo build --release --locked --manifest-path rust/Cargo.toml -p keytrail-server

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-0 ca-certificates && rm -rf /var/lib/apt/lists/* && mkdir -p /state && chown 10001:10001 /state
COPY --from=build /build/rust/target/release/keytrail-server /usr/local/bin/keytrail-server
USER 10001:10001
WORKDIR /state
VOLUME ["/state"]
EXPOSE 8787
ENTRYPOINT ["/usr/local/bin/keytrail-server"]
CMD ["serve", "/state/config.json"]
