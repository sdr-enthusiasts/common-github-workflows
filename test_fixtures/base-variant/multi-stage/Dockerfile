FROM rust:1.97.0-trixie AS builder
RUN cargo build --release

FROM --platform=$BUILDPLATFORM ghcr.io/sdr-enthusiasts/docker-baseimage:mlatclient AS mlat

from ghcr.io/sdr-enthusiasts/docker-baseimage:base
LABEL org.opencontainers.image.base.name="ghcr.io/sdr-enthusiasts/docker-baseimage:base"
COPY --from=ghcr.io/sdr-enthusiasts/docker-baseimage:wreadsb /usr/local/bin/readsb /usr/local/bin/
COPY --from=builder /target/release/app /usr/local/bin/
RUN --mount=type=bind,from=ghcr.io/sdr-enthusiasts/docker-baseimage:mlatclient,source=/,target=/mlat \
    --mount=type=bind,from=ghcr.io/sdr-enthusiasts/docker-baseimage:soapy-full,source=/,target=/soapy \
    echo "built on ghcr.io/sdr-enthusiasts/docker-baseimage:base"
# FROM ghcr.io/sdr-enthusiasts/docker-baseimage:dump978-full
