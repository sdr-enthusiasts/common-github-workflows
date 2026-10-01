# Generic image used to self-test sdre.yml.
#
# This is deliberately built on the org base image and ships real s6 services, so
# that the runtime verification step in sdre.yml is exercised end to end against
# something shaped like an actual downstream image. Before it had any services,
# the harness could not have detected the s6-overlay 3.2.3.1 bundle regression at
# all -- which is precisely how that regression reached users.
FROM ghcr.io/sdr-enthusiasts/docker-baseimage:base@sha256:8ee0c9df5375cc9dcd63e006aac598cd68d28364d69c8dea246c1d5a4d287d79

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Registers test-longrun and test-oneshot under user-bundles.d.
COPY ./test_image_rootfs/etc /etc

RUN echo "v1.0.0" > /IMAGE_VERSION
