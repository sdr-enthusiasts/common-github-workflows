# Fixture: an image with no s6-overlay at all. Must PASS as not-applicable.
# Regression guard: sdr-enthusiasts/docker-sdrreceiver ships a hand-written /init
# and no s6-rc. Testing for /init would misclassify it, and treating it as a base
# image made `s6-rc-db` not-found error text get compared against the expected
# service set, producing a bogus R3 failure.
FROM debian:trixie-slim@sha256:f6b08b09a05725f9431502d3b5714f5c4576e82c1a84fa1debe0c24a7e0c3ec4
CMD ["/bin/true"]
