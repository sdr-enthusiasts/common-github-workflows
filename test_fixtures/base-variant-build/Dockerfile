# Built by test.yml with base_variant: forky. The FROM below names the stable
# image on purpose: the build only passes if sdre.yml rewrote it to forky-base.
FROM ghcr.io/sdr-enthusiasts/docker-baseimage:base

RUN set -x && \
    . /etc/os-release && \
    echo "built on: ${PRETTY_NAME}" && \
    grep -q forky /etc/os-release
