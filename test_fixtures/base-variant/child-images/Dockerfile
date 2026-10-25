FROM ghcr.io/sdr-enthusiasts/docker-tar1090:telegraf
# hadolint ignore=DL3022
COPY --from=ghcr.io/sdr-enthusiasts/docker-tar1090 /usr/local/bin/x /usr/local/bin/
# hadolint ignore=DL3022
COPY --from=ghcr.io/sdr-enthusiasts/docker-tar1090:latest /usr/local/bin/y /usr/local/bin/
# hadolint ignore=DL3022
COPY --from=ghcr.io/other-org/docker-tar1090:latest /usr/local/bin/z /usr/local/bin/
