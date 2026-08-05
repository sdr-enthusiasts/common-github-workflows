# Fixture: service defined but never registered, so it can never run.
# Must be caught by S2. This is also the case that must NOT be confused with a
# legitimate base image, which has no service definitions at all.
FROM harness:local
RUN rm -f /etc/s6-overlay/user-bundles.d/user/contents.d/test-longrun \
    && rm -f /etc/s6-overlay/user-bundles.d/user/contents.d/test-oneshot
