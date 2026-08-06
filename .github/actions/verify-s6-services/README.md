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

## Usage

Wired into `sdre.yml` by default; `verify_s6_enabled: false` disables it. Direct
use:

```yaml
- uses: $/.github/actions/verify-s6-services
  with:
    image: my-image:local
```

The script is also runnable by hand, which is the fastest way to triage:

```bash
.github/actions/verify-s6-services/verify-s6-services.sh \
  --image ghcr.io/sdr-enthusiasts/docker-adsbhub:latest \
```

Exit codes: `0` pass, `1` fail, `2` inconclusive, `3` usage error.

## Escape hatches

All opt-in, none required.

| input            | purpose                                                   |
| ---------------- | --------------------------------------------------------- |
| `container_env`  | newline-separated `KEY=VALUE` passed into the container   |
| `http_probe`     | URL that must answer from inside the container            |
| `strict_startup` | fail on services down even when credentials were withheld |
| `runtime_checks` | `false` for static-only, for non-executable architectures |

## What this does NOT catch

Stated plainly, so the green tick is not over-trusted.

- **Whether a service does anything useful.** R4 asserts s6 considers a service
  up. A service that starts, logs an error and idles forever passes.
- **A service broken in a way that still lets it start.** R4 asserts s6 reached
  the `up` state, nothing more.
- **A service that wrongly claims 78.** The contract is only as good as its use:
  a service that exits 78 when it is genuinely broken is excused. It is visible
  in the source and named in the job summary, but nothing detects a false claim.
- **Anything requiring credentials or hardware, in the functional sense.** The
  service is asserted to reach the `up` state, not to authenticate, decode or
  feed anything.
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
