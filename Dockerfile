# Generic image to test builds

FROM debian:trixie-20251208-slim@sha256:e711a7b30ec1261130d0a121050b4ed81d7fb28aeabcf4ea0c7876d4e9f5aca2

WORKDIR /opt/sdre
COPY ./test_image_rootfs ./
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN echo "v1.0.0" > /IMAGE_VERSION
