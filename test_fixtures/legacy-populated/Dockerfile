# Fixture: ships the deprecated s6-rc.d/user bundle, populated.
# s6-overlay's compatibility shim engages and ignores all of user-bundles.d.
# Must be caught by S1 (static) and R1 (deprecation warning in the log).
FROM harness:local
RUN mkdir -p /etc/s6-overlay/s6-rc.d/user/contents.d \
    && echo bundle > /etc/s6-overlay/s6-rc.d/user/type \
    && touch /etc/s6-overlay/s6-rc.d/user/contents.d/test-longrun
