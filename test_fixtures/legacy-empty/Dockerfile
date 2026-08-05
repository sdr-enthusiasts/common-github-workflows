# Fixture: the invisible variant. An EMPTY s6-rc.d/user is just as fatal, because
# the shim only tests -d. git cannot track an empty directory, so COPY rootfs/ /
# can reintroduce one that is not visible anywhere in the source tree.
# This is the exact shape of the regression that reached users.
FROM harness:local
RUN mkdir -p /etc/s6-overlay/s6-rc.d/user
