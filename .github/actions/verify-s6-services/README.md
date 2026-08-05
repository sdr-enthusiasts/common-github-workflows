# Verify s6 services

Asserts that a built image will actually **run** its s6-overlay services, rather
than only that it built.

## Why

s6-overlay 3.2.3.1 relocated the s6-rc user bundle directory. Every downstream
image in this org silently stopped starting its services. CI was green
throughout, because "the image built" and "the image works" are different claims
and nothing asserted the second one. Users reported the breakage before CI did.

The failure mode is hard to see on purpose:

- if anything in the image still ships `/etc/s6-overlay/s6-rc.d/user`, the
  s6-overlay compatibility shim silently discards **all** of `user-bundles.d`;
- an **empty** such directory is equally fatal, because the shim only tests `-d`;
- git does not track empty directories, so `COPY rootfs/ /` can reintroduce one
  that is invisible in the source tree.

In all of those cases the container still boots and still exits 0.

So `did the container stay up?` is the wrong assertion. It is simultaneously too
weak (a container can be up with nothing running) and unachievable for much of
this fleet, where feeders exit without credentials and some images need real
hardware. This action asserts the **s6 service graph** instead, which is
discoverable from the image itself and needs no per-repo configuration.

## What it asserts

Static checks execute nothing from the image. They use `docker create` plus
`docker cp`, so they work on any architecture with no qemu and no emulation cost.

| id  | check                                                                  |
| --- | ---------------------------------------------------------------------- |
| S1  | `s6-rc.d/user` and `s6-rc.d/user2` are absent (populated **or** empty) |
| S2  | services are registered, or the image is genuinely a base image        |
| S3  | every registration has a matching service definition                   |

Runtime checks boot the container and interrogate the compiled database.

| id  | check                                                               |
| --- | ------------------------------------------------------------------- |
| R1  | no `defining user bundles in ... is deprecated` warning in the logs |
| R2  | no `s6-rc-compile: fatal` in the logs                               |
| R3  | the compiled user bundle equals the expected set                    |
| R4  | every service in the bundle's transitive closure is up              |
| P1  | optional, opt-in: an HTTP URL answers inside the container          |

R3 is the decisive one. It is what comes back wrong when the shim silently drops
`user-bundles.d` while everything else still looks fine.

**No single check is sufficient**, which the fixtures in `test_fixtures/`
demonstrate:

- a _populated_ legacy bundle passes R3, because the shim compiled the legacy
  bundle and it happened to hold the same services. Only S1 and R1 catch it.
- an _empty_ legacy bundle passes S1's sibling checks and R1 alone would be
  ambiguous. R3 is what shows the services were dropped.

R4 uses the **transitive closure** (`s6-rc-db all-dependencies user`), not the
registered set, because some services are reachable only through another
service's `dependencies.d` and are never registered directly.
`docker-tar1090`'s `09-rtlsdr-biastee` is pulled in by `readsb`. Asserting only
registrations would miss a broken dependency edge.

## Credentials are not required

The base sets `S6_BEHAVIOUR_IF_STAGE2_FAILS=2`, so one oneshot failing for want
of a key halts the container before the compiled database can be read. When that
happens the action re-runs with `S6_BEHAVIOUR_IF_STAGE2_FAILS=0` so s6 stays
alive, and S1-S3 plus R1-R3 still run with no credentials at all. R4 is then
reported as _not assessed_ rather than passed or failed.

This turns an "untestable feeder container" into a "bundle-verifiable container"
with zero configuration.

A container can also sit in state `running` while s6-rc bringup was aborted
entirely, so nothing is up at all — `docker-aprs-tracker` does this when no
soundcard is present. An empty up-list is reported as a configuration or hardware
prerequisite, not a failure.

## Baseline comparison

During the migration, comparing against the currently published image was three
times the only thing that distinguished a real regression from pre-existing
behaviour. `baseline` makes that first-class: if the target fails, the same
checks run against the published image.

The comparison is on failure **signatures** — check id plus the offending service
names — not on bare check ids. Without that, `R4:service-a` failing on the
published image and `R4:service-b` failing here would both reduce to `R4` and a
genuinely new fault would be misreported as pre-existing.

Deliberate service changes do not trip anything, because every assertion is
self-referential: the expected set is read from the image under test, so removing
a service shrinks both sides of R3 together. The baseline is only ever consulted
when the image has already failed on its own terms.

## Usage

Wired into `sdre.yml` by default; `verify_s6_enabled: false` disables it. Direct
use:

```yaml
- uses: $/.github/actions/verify-s6-services
  with:
    image: my-image:local
    baseline: ghcr.io/sdr-enthusiasts/my-image:latest
```

The script is also runnable by hand, which is the fastest way to triage:

```bash
.github/actions/verify-s6-services/verify-s6-services.sh \
  --image ghcr.io/sdr-enthusiasts/docker-adsbhub:latest \
  --baseline ghcr.io/sdr-enthusiasts/docker-adsbhub:latest
```

Exit codes: `0` pass, `1` fail, `2` inconclusive, `3` usage error.

## Escape hatches

All opt-in, none required.

| input                    | purpose                                                   |
| ------------------------ | --------------------------------------------------------- |
| `container_env`          | newline-separated `KEY=VALUE` passed into the container   |
| `http_probe`             | URL that must answer from inside the container            |
| `strict_startup`         | fail on services down even when credentials were withheld |
| `runtime_checks`         | `false` for static-only, for non-executable architectures |
| `preexisting_is_failure` | fail even when the baseline shows the fault is old        |

## What this does NOT catch

Stated plainly, so the green tick is not over-trusted.

- **Whether a service does anything useful.** R4 asserts s6 considers a service
  up. A service that starts, logs an error and idles forever passes.
- **A genuinely broken service, when the image cannot start without
  credentials.** This is the biggest blind spot and it is structural. A oneshot
  that fails because a key is missing and a oneshot that fails because it is
  broken look identical: both exit nonzero, and because the base sets
  `S6_BEHAVIOUR_IF_STAGE2_FAILS=2` both halt the container. Verification retries
  in degraded mode and reports R4 as _not assessed_, so **the build passes**.
  Verified: a fixture whose oneshot does nothing but `exit 1` passes. This is the
  direct price of making credential-less feeders verifiable at all — the
  alternative was verifying nothing. Bundle integrity is still asserted; service
  startup is not. `strict_startup: true` fails instead, and is appropriate only
  for images that start cleanly with no configuration.
- **Anything requiring credentials or hardware.** Feeders and SDR images run in
  degraded mode, where R4 is explicitly _not assessed_. The bundle is verified;
  the feeding is not.
- **Correct application behaviour or output.** No decoding, no data flow, no
  network egress, no web UI correctness. The `http_probe` is a liveness ping, not
  a functional test.
- **Configuration options.** These images have dozens each. Per-option testing is
  out of scope by design; combinatorially it cannot be maintained by one person.
- **Architecture-specific runtime faults.** Runtime checks run on one platform
  (`linux/amd64` by default). Static checks run on every platform, so a per-arch
  difference in _registration_ is caught, but a service that starts on amd64 and
  crashes on arm is not.
- **Crash loops or later failures.** The container is sampled once, after
  `settle_seconds`. A service that dies at minute five is not seen.
- **Runtime-generated service definitions.** Services written by a oneshot at
  boot are not in the static set, so S2 and S3 cannot see them. R3 and R4 will.
- **Non-s6 images.** An image with no s6-overlay v3 is reported as
  not-applicable and vacuously passes. Detection is on
  `/package/admin/s6-overlay`, not on `/init`, because s6-overlay v2 images and
  images with a hand-written `/init` both ship the latter. If such an image was
  _supposed_ to run s6 services, that absence is the bug and this will not tell
  you.
- **Regressions already present in the published image**, when `baseline` is
  enabled. Those are reported as pre-existing and, by default, do not fail the
  build. They are still real problems.
