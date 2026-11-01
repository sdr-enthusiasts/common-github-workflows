# Built by test.yml with base_variant: forky. The FROM below names the stable
# image on purpose: the build only passes if sdre.yml rewrote it to forky-base.
FROM ghcr.io/sdr-enthusiasts/docker-baseimage:base@sha256:b38e493a7bde9d9752b5152b2780449bcec1a5c11725ca05173a8414fccba371

RUN set -x && \
    . /etc/os-release && \
    echo "built on: ${PRETTY_NAME}" && \
    grep -q forky /etc/os-release
