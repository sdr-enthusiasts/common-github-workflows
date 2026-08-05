# Fixture: the needs-credential image PLUS a newly added, outright broken oneshot.
# This is the case that used to ship green: in degraded mode R4 is undecidable, so
# a genuinely broken service was indistinguishable from a missing credential.
# Compared against needs-credential it must fail R6, while needs-key is absorbed
# as pre-existing.
FROM harness:local
COPY rootfs/ /
