# Fixture: an image with no s6-overlay at all. Must PASS as not-applicable.
# Regression guard: sdr-enthusiasts/docker-sdrreceiver ships a hand-written /init
# and no s6-rc. Testing for /init would misclassify it, and treating it as a base
# image made `s6-rc-db` not-found error text get compared against the expected
# service set, producing a bogus R3 failure.
FROM debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a
CMD ["/bin/true"]
