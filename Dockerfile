# Generic image to test builds

FROM debian:bullseye
#hadolint ignore=DL3008,DL3003,DL3045
COPY ./test_image_rootfs ./
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN echo "v1.0.0" > /IMAGE_VERSION
