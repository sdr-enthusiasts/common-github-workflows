# Generic image to test builds

FROM debian:bullseye
COPY ./test_image_rootfs ./
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
RUN echo "v1.0.0" > /IMAGE_VERSION
