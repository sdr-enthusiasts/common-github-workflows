# Fixture: a feeder-shaped image whose oneshot exits nonzero without a credential.
# Stands in for the ~half of the fleet that cannot start unconfigured. Used as the
# BASELINE for the two startup-comparison fixtures, and must itself pass: being
# down for want of a key is this image's normal state, not a fault.
FROM harness:local
COPY rootfs/ /
