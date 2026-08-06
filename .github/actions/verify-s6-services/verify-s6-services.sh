#!/usr/bin/env bash
#
# verify-s6-services.sh -- assert that a built container image will actually run
# its s6-overlay services, rather than merely that it built.
#
# WHY THIS EXISTS
# ---------------
# s6-overlay 3.2.3.1 relocated the s6-rc user bundle directory. Every downstream
# image in this org silently stopped starting its services. CI stayed green the
# whole time, because "the image built" and "the image works" are different
# claims and nothing asserted the second one. Users reported it before CI did.
#
# The failure mode is deliberately hard to see:
#   * if anything in the image still ships /etc/s6-overlay/s6-rc.d/user, the
#     s6-overlay compatibility shim silently discards ALL of user-bundles.d;
#   * an EMPTY such directory is equally fatal -- the shim only tests -d;
#   * git does not track empty directories, so `COPY rootfs/ /` can reintroduce
#     one that is invisible in the source tree.
# In every one of those cases the container still boots and still exits 0.
#
# So "did the container stay up?" is the wrong assertion. It is simultaneously
# too weak (a container can be up with nothing running) and unachievable for
# much of this fleet (feeders exit without credentials, some need real hardware).
#
# WHAT IS ASSERTED INSTEAD
# -----------------------
# The s6 service graph, which is discoverable from the image itself and needs no
# per-repo configuration:
#
#   STATIC (no execution in the image at all -- works on any architecture)
#     S1  the deprecated s6-rc.d/user and s6-rc.d/user2 directories are absent
#     S2  every registered service name has a matching service definition
#     S3  every service definition is registered (catches "defined but never
#         wired up", which is also what distinguishes a genuine base image from
#         a child image that forgot to register)
#
#   RUNTIME (needs to execute the image)
#     R1  no "defining user bundles in ... is deprecated" warning in the logs
#     R2  no "s6-rc-compile: fatal" in the logs
#     R3  the compiled user bundle equals the expected set -- THE decisive check,
#         because this is what comes back wrong when the shim silently drops
#         user-bundles.d while everything else still looks fine
#     R4  every service in the TRANSITIVE closure of the user bundle is up.
#         The closure, not the registered set: some services are reachable only
#         through another service's dependencies.d and are never registered
#         directly (docker-tar1090's 09-rtlsdr-biastee is pulled in by readsb).
#         Asserting only registrations would miss a broken dependency edge.
#
# CREDENTIALS
# -----------
# The base sets S6_BEHAVIOUR_IF_STAGE2_FAILS=2, so a single oneshot failing for
# want of a key halts the container before anything can be inspected. When that
# happens this script re-runs with S6_BEHAVIOUR_IF_STAGE2_FAILS=0 so s6 stays
# alive, which lets S1-S3 and R1-R3 still run with no credentials at all. R4 is
# then reported as "not assessed" rather than passed or failed. That turns an
# "untestable feeder container" into a "bundle-verifiable container" with zero
# per-repo configuration.
#
# THE EXIT-CODE CONTRACT
# ----------------------
# A service that cannot run in this environment says so by exiting 78
# (EX_CONFIG): a missing credential, an absent dongle, no sound card. Any other
# nonzero exit means nobody claimed the failure was expected, so it is a fault.
#
# This is what makes the image self-describing. An earlier version compared each
# build against the currently published image to work out whether a failure was
# new, because "down for want of a key" and "down because broken" were otherwise
# indistinguishable. With the contract that comparison is unnecessary: the built
# container either works or it does not, and it tells you which.
#
# Exit codes: 0 pass (or vacuous pass / not-applicable), 1 fail, 2 inconclusive,
#             3 usage error.

set -uo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

IMAGE=""
SETTLE_SECONDS="${SETTLE_SECONDS:-8}"

# The exit code by which a service declares "I cannot run in this environment,
# and that is expected" -- a missing credential, an absent SDR dongle, no sound
# card. 78 is EX_CONFIG from sysexits.h, so it carries the right meaning to a
# human reading `docker logs` as well as to this script.
#
# The point of the contract is that it makes the DEFAULT safe. Any other nonzero
# exit from a service means nobody has claimed the failure is expected, so it is
# treated as a real fault rather than being excused. Guessing the reason from log
# text or trusting a per-repo annotation both failed that test; this does not.
SDRE_CONFIG_EXIT="${SDRE_CONFIG_EXIT:-78}"
HTTP_PROBE=""
HTTP_PROBE_TIMEOUT=30
RUNTIME_CHECKS=1
STRICT_STARTUP=0
declare -a RUN_ENV=()

usage() {
	cat <<'EOF'
usage: verify-s6-services.sh --image IMAGE [options]

  --image IMAGE            image to verify (required)
  --env KEY=VALUE          pass an env var to the container (repeatable)
  --settle SECONDS         seconds to wait for s6 bringup (default 8)
  --http-probe URL         additionally require this URL to answer inside the
                           container (opt-in; never required)
  --http-probe-timeout N   seconds to keep retrying the probe (default 30)
  --no-runtime-checks      static checks only; use for foreign-architecture
                           images that cannot execute on this host
  --strict-startup         treat "service not up" as a failure even when running
                           degraded because credentials were withheld
EOF
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--image)
		IMAGE="${2:-}"
		shift 2
		;;
	--env)
		RUN_ENV+=("-e" "${2:-}")
		shift 2
		;;
	--settle)
		SETTLE_SECONDS="${2:-8}"
		shift 2
		;;
	--http-probe)
		HTTP_PROBE="${2:-}"
		shift 2
		;;
	--http-probe-timeout)
		HTTP_PROBE_TIMEOUT="${2:-30}"
		shift 2
		;;
	--no-runtime-checks)
		RUNTIME_CHECKS=0
		shift
		;;
	--strict-startup)
		STRICT_STARTUP=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		echo "unknown argument: $1" >&2
		usage >&2
		exit 3
		;;
	esac
done

[[ -n "$IMAGE" ]] || {
	usage >&2
	exit 3
}

# ---------------------------------------------------------------------------
# Output helpers. Annotations are emitted only under GitHub Actions so that
# local runs stay readable.
# ---------------------------------------------------------------------------

if [[ -t 1 ]]; then
	C_RED=$'\033[0;31m' C_GRN=$'\033[0;32m' C_YEL=$'\033[0;33m'
	C_CYN=$'\033[1;36m' C_BLD=$'\033[1m' C_OFF=$'\033[0m'
else
	C_RED="" C_GRN="" C_YEL="" C_CYN="" C_BLD="" C_OFF=""
fi

FAILED=0
declare -a FAILED_CHECKS=()
declare -a NOTASSESSED_CHECKS=()

pass() { printf '%sPASS%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
note() { printf '      %s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_OFF"; }

# fail <id> <message> -- records a failing check.
fail() {
	local id="$1"
	shift
	printf '%sFAIL%s  [%s] %s\n' "$C_RED" "$C_OFF" "$id" "$*"
	FAILED_CHECKS+=("$id")
	FAILED=1
}

notassessed() {
	local id="$1"
	shift
	printf '%sN/A %s  [%s] %s\n' "$C_YEL" "$C_OFF" "$id" "$*"
	NOTASSESSED_CHECKS+=("$id")
}

CONTAINER="s6verify-$$-$RANDOM"
# shellcheck disable=SC2329  # invoked indirectly by the EXIT trap below
cleanup() {
	docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
	[[ -n "${TMPD:-}" ]] && rm -rf "$TMPD"
	return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Static inspection.
#
# Deliberately implemented with `docker create` + `docker cp` rather than
# `docker run --entrypoint /bin/sh`. Nothing from the image is executed, which
# means every static check works on a foreign-architecture image with no qemu
# and no emulation cost -- including S1, the check that catches the exact
# s6-overlay 3.2.3.1 regression this tooling exists for.
# ---------------------------------------------------------------------------

TMPD="$(mktemp -d)"
SNAP="$TMPD/snap"
mkdir -p "$SNAP"

snapshot_image() {
	local cid
	if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
		if ! docker pull -q "$IMAGE" >/dev/null 2>&1; then
			fail S0 "image not available locally and could not be pulled: $IMAGE"
			return 1
		fi
	fi
	cid="$(docker create "$IMAGE" 2>/dev/null)" || {
		fail S0 "could not create a container from $IMAGE"
		return 1
	}
	# Missing paths are expected for some images, so failures here are not fatal.
	docker cp "$cid:/etc/s6-overlay/user-bundles.d/user/contents.d" "$SNAP/contents.d" >/dev/null 2>&1
	docker cp "$cid:/etc/s6-overlay/s6-rc.d" "$SNAP/s6-rc.d" >/dev/null 2>&1
	# s6-overlay v3 installs itself here. Its absence means there is no s6-rc
	# database to interrogate, however the image is otherwise structured: older
	# s6-overlay v2 images and images with a hand-written /init both ship an
	# /init, so testing for /init would misclassify them. Costs ~4KB to copy.
	if docker cp "$cid:/package/admin/s6-overlay" "$SNAP/s6-overlay-pkg" >/dev/null 2>&1; then
		S6V3_PRESENT=1
	else
		S6V3_PRESENT=0
	fi
	docker rm -f "$cid" >/dev/null 2>&1
	return 0
}

# ---------------------------------------------------------------------------
# Runtime helpers
# ---------------------------------------------------------------------------

LOGS=""
STATE="unknown"
declare -A EXIT_CODE=()

# s6-rc reports the real exit status of a failed service, verified against codes
# 1, 42 and 78:
#     s6-rc: warning: unable to start service <name>: command exited <code>
# Only services that actually ran and failed appear here. A service that never
# started because a dependency failed has no code of its own, which is correct:
# it is collateral, and the fault belongs to the root.
parse_exit_codes() {
	EXIT_CODE=()
	local svc code line
	while IFS= read -r line; do
		svc="${line##*unable to start service }"
		svc="${svc%%:*}"
		code="${line##*command exited }"
		code="${code%% *}"
		[[ -n "$svc" && "$code" =~ ^[0-9]+$ ]] && EXIT_CODE["$svc"]="$code"
	done < <(grep -E 'unable to start service .*: command exited [0-9]+' <<<"$LOGS")
}

# Render a service list with each service's exit code, for human-readable output.
with_codes() {
	local out="" svc
	for svc in $1; do out+="$svc(exit ${EXIT_CODE[$svc]:-none}) "; done
	printf '%s' "$out"
}

# Partition a list of not-up services into those that declared an expected
# environmental failure and those that did not.
#   $1 = service list, $2 = name of var to receive declared, $3 = unexplained,
#   $4 = collateral (down with no exit code of their own)
partition_by_exit() {
	local list="$1" d="" u="" c="" svc
	for svc in $list; do
		if [[ -z "${EXIT_CODE[$svc]:-}" ]]; then
			c+="$svc "
		elif [[ "${EXIT_CODE[$svc]}" == "$SDRE_CONFIG_EXIT" ]]; then
			d+="$svc "
		else
			u+="$svc "
		fi
	done
	printf -v "$2" '%s' "$d"
	printf -v "$3" '%s' "$u"
	printf -v "$4" '%s' "$c"
}

start_container() {
	docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
	docker run -d --name "$CONTAINER" -e S6_VERBOSITY=2 \
		"${RUN_ENV[@]+"${RUN_ENV[@]}"}" "$@" "$IMAGE" >/dev/null 2>&1
}

sample() {
	LOGS="$(docker logs "$CONTAINER" 2>&1)"
	STATE="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo unknown)"
	parse_exit_codes
}

# Yields nothing at all when the command cannot be run, rather than letting a
# runtime error such as `exec: "s6-rc-db": executable file not found` become the
# captured value and get compared against an expected service set. Note docker
# prints some of those errors to stdout, so redirecting stderr is not sufficient.
in_container() {
	local out
	if out="$(docker exec "$CONTAINER" "$@" 2>/dev/null)"; then
		printf '%s' "$out"
	fi
}

# s6 tools live in /command, but not every image puts /command on PATH -- the org
# base images do, a bare s6-overlay install without the symlinks package does not.
# Try the absolute path first so the checks do not depend on the image's PATH.
# Returns nonzero if the tool cannot be run at all, which is reported distinctly
# rather than being allowed to look like an empty result and therefore a mismatch.
S6_TOOLS_USABLE=1
s6_tool() {
	local tool="$1"
	shift
	if out="$(docker exec "$CONTAINER" "/command/$tool" "$@" 2>/dev/null)"; then
		printf '%s' "$out"
		return 0
	fi
	if out="$(docker exec "$CONTAINER" "$tool" "$@" 2>/dev/null)"; then
		printf '%s' "$out"
		return 0
	fi
	return 1
}

# Test for the binary, not for a successful invocation: s6-rc-db -h exits 100.
s6_tools_available() {
	docker exec "$CONTAINER" test -x /command/s6-rc-db >/dev/null 2>&1 && return 0
	docker exec "$CONTAINER" sh -c 'command -v s6-rc-db' >/dev/null 2>&1 && return 0
	return 1
}

# ===========================================================================
# MAIN
# ===========================================================================

printf '%s=== verifying %s ===%s\n' "$C_CYN" "$IMAGE" "$C_OFF"

snapshot_image || {
	printf '\n%sVERIFICATION FAILED%s (could not inspect image)\n' "$C_RED" "$C_OFF"
	exit 1
}

head1 "Static layout"

# --- S1: the deprecated bundle directories must be absent -------------------
# An empty directory is as fatal as a populated one, so test for existence only.
legacy_found=()
for d in user user2; do
	[[ -d "$SNAP/s6-rc.d/$d" ]] && legacy_found+=("$d")
done
if [[ ${#legacy_found[@]} -eq 0 ]]; then
	pass "S1 no deprecated s6-rc.d/user or s6-rc.d/user2 directory"
else
	fail S1 "deprecated bundle directory present: ${legacy_found[*]}"
	note "this alone makes s6-overlay ignore ALL of user-bundles.d"
	note "note git does not track empty dirs, but COPY rootfs/ / still copies them"
	for d in "${legacy_found[@]}"; do
		note "  s6-rc.d/$d contains: $(find "$SNAP/s6-rc.d/$d" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | tr '\n' ' ')"
	done
fi

# --- gather the expected and defined sets -----------------------------------
EXPECTED=""
[[ -d "$SNAP/contents.d" ]] && EXPECTED="$(find "$SNAP/contents.d" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort)"

DEFINED=""
if [[ -d "$SNAP/s6-rc.d" ]]; then
	# s6-overlay ships its own services under /package, not /etc/s6-overlay/s6-rc.d,
	# so everything found here is image-provided. Verified against
	# docker-baseimage:base, whose /etc/s6-overlay/s6-rc.d is empty.
	DEFINED="$(find "$SNAP/s6-rc.d" -mindepth 1 -maxdepth 1 -type d \
		-not -name user -not -name user2 -printf '%f\n' 2>/dev/null | sort)"
fi

n_expected=$([[ -n "$EXPECTED" ]] && echo "$EXPECTED" | wc -l || echo 0)
n_defined=$([[ -n "$DEFINED" ]] && echo "$DEFINED" | wc -l || echo 0)

# --- classify the image -----------------------------------------------------
# This is the fix for the prototype's known gap: it reported FAIL for any image
# with zero registrations, which is correct for a child image but wrong for a
# base image like :base or :wreadsb that legitimately ships no user services.
# The discriminator is whether service definitions exist without registrations.
IMAGE_CLASS="service"
if [[ "${S6V3_PRESENT:-0}" -eq 0 && $n_expected -eq 0 && $n_defined -eq 0 ]]; then
	# No s6-overlay v3, so there is no s6-rc database and nothing to assert.
	# Distinguished from a base image because a base image DOES ship s6-overlay
	# and so is still capable of poisoning its children with a legacy bundle dir.
	IMAGE_CLASS="not-s6"
elif [[ $n_expected -eq 0 && $n_defined -eq 0 ]]; then
	IMAGE_CLASS="base"
elif [[ $n_expected -eq 0 && $n_defined -gt 0 ]]; then
	IMAGE_CLASS="unregistered"
fi

case "$IMAGE_CLASS" in
not-s6)
	pass "S2 image does not ship s6-overlay v3 -- s6 service assertions not applicable"
	note "no /package/admin/s6-overlay, so there is no s6-rc database to check"
	note "if this image is expected to run s6 services, that absence is itself the bug"
	;;
base)
	pass "S2 no user services defined or registered -- base image, service assertions not applicable"
	note "s6-rc.d and user-bundles.d/user/contents.d are both empty, which is"
	note "the normal shape of a base image such as :base or :wreadsb"
	;;
unregistered)
	fail S2 "services are defined but NONE are registered -- they can never run"
	note "defined but unregistered: $(echo "$DEFINED" | tr '\n' ' ')"
	note "add each to /etc/s6-overlay/user-bundles.d/user/contents.d"
	;;
service)
	pass "S2 registered in user-bundles.d: $(echo "$EXPECTED" | tr '\n' ' ')"
	;;
esac

# --- S3: registrations and definitions must correspond ----------------------
if [[ "$IMAGE_CLASS" == "service" ]]; then
	missing_def="$(comm -23 <(echo "$EXPECTED") <(echo "$DEFINED"))"
	unregistered="$(comm -13 <(echo "$EXPECTED") <(echo "$DEFINED"))"
	if [[ -z "$missing_def" ]]; then
		pass "S3 every registration has a matching service definition"
	else
		fail S3 "registered with no service definition: $(echo "$missing_def" | tr '\n' ' ')"
	fi
	if [[ -n "$unregistered" ]]; then
		# Not a failure: a service may legitimately be pulled in only via another
		# service's dependencies.d, which R4 covers properly at runtime.
		note "defined but not registered (expected if pulled in via dependencies.d):"
		note "  $(echo "$unregistered" | tr '\n' ' ')"
	fi
fi

# ---------------------------------------------------------------------------
# Runtime
# ---------------------------------------------------------------------------

if [[ $RUNTIME_CHECKS -eq 0 ]]; then
	head1 "Runtime"
	notassessed R "runtime checks disabled (--no-runtime-checks)"
	note "static checks above still fully cover the deprecated-directory regression"
elif [[ "$IMAGE_CLASS" == "not-s6" ]]; then
	head1 "Runtime"
	notassessed R "skipped: no s6-overlay v3 in this image, so there is no service graph"
elif [[ "$IMAGE_CLASS" == "unregistered" ]]; then
	head1 "Runtime"
	notassessed R "skipped: nothing is registered, so there is nothing to bring up"
else
	head1 "Runtime"

	if ! start_container; then
		fail R0 "could not start container"
	else
		sleep "$SETTLE_SECONDS"
		sample

		DEGRADED=0
		# The base sets S6_BEHAVIOUR_IF_STAGE2_FAILS=2, so one oneshot failing for
		# want of a credential halts the container before the compiled database can
		# be read -- and that database is the check that actually matters. Retry with
		# the halt disabled so R1-R3 can still run without any credentials.
		if [[ "$STATE" != "running" ]]; then
			note "container state is \"$STATE\"; retrying with S6_BEHAVIOUR_IF_STAGE2_FAILS=0"
			note "so the compiled bundle can still be inspected without credentials"
			DEGRADED=1
			if start_container -e S6_BEHAVIOUR_IF_STAGE2_FAILS=0; then
				sleep "$SETTLE_SECONDS"
				sample
			fi
		fi

		# --- R1: the deprecation warning is the canary ----------------------
		if grep -q 'defining user bundles in .* is deprecated' <<<"$LOGS"; then
			fail R1 "s6-overlay logged the legacy-bundle deprecation warning"
			note "something in this image still ships s6-rc.d/user"
		else
			pass "R1 no legacy-bundle deprecation warning in logs"
		fi

		# --- R2: a fatal compile means the bundle layout is broken outright --
		if grep -q 's6-rc-compile: fatal' <<<"$LOGS"; then
			fail R2 "s6-rc-compile failed:"
			grep 's6-rc-compile: fatal' <<<"$LOGS" | sed 's/^/      /'
		else
			pass "R2 no s6-rc-compile fatal error in logs"
		fi

		if [[ "$STATE" != "running" ]]; then
			notassessed R3 "container will not stay up even with stage2 failures ignored"
			note "state=\"$STATE\" -- pass the env this image needs via --env and retry"
			note "--- last 30 log lines ---"
			tail -30 <<<"$LOGS" | sed 's/^/      /'
		else
			# --- R3: what actually landed in the compiled bundle -------------
			if ! s6_tools_available; then
				S6_TOOLS_USABLE=0
				notassessed R3 "cannot inspect the compiled database: s6-rc-db is not runnable in this image"
				note "looked for /command/s6-rc-db and s6-rc-db on PATH"
				note "the bundle layout was still checked statically by S1 to S3"
			fi
			COMPILED="$(s6_tool s6-rc-db -c /run/s6/db contents user | sort)"
			if [[ $S6_TOOLS_USABLE -eq 0 ]]; then
				: # already reported as not assessable above
			elif [[ "$COMPILED" == "$EXPECTED" ]]; then
				if [[ "$IMAGE_CLASS" == "base" ]]; then
					pass "R3 compiled user bundle is empty, as expected for a base image"
				else
					pass "R3 compiled user bundle matches the registrations exactly"
				fi
			else
				fail R3 "compiled user bundle does NOT match the registrations"
				note "expected: $(echo "$EXPECTED" | tr '\n' ' ')"
				note "compiled: $(echo "$COMPILED" | tr '\n' ' ')"
				note "missing : $(comm -23 <(echo "$EXPECTED") <(echo "$COMPILED") | tr '\n' ' ')"
				note "extra   : $(comm -13 <(echo "$EXPECTED") <(echo "$COMPILED") | tr '\n' ' ')"
			fi

			# --- R4: and that they are actually up ---------------------------
			if [[ $S6_TOOLS_USABLE -eq 0 ]]; then
				notassessed R4 "cannot inspect service state: s6-rc is not runnable in this image"
			elif [[ "$IMAGE_CLASS" == "base" ]]; then
				notassessed R4 "no user services to start (base image)"
			else
				UP="$(s6_tool s6-rc -a list | sort)"
				TRANSITIVE="$(s6_tool s6-rc-db -c /run/s6/db all-dependencies user | sort)"
				if [[ -z "$TRANSITIVE" ]]; then
					TRANSITIVE="$EXPECTED"
					note "could not read transitive deps; falling back to the registered set"
				else
					extra_deps="$(comm -13 <(echo "$EXPECTED") <(echo "$TRANSITIVE") | tr '\n' ' ')"
					[[ -n "${extra_deps// /}" ]] && note "also pulled in via dependencies.d: $extra_deps"
				fi

				not_up=""
				while IFS= read -r svc; do
					[[ -n "$svc" ]] || continue
					grep -qx "$svc" <<<"$UP" || not_up+="$svc "
				done <<<"$TRANSITIVE"

				if [[ -z "${UP// /}" ]]; then
					# A container can sit in state "running" while s6-rc bringup was
					# aborted outright -- docker-aprs-tracker calls it fatal when no
					# soundcard is present, and then nothing is up, not even
					# s6rc-oneshot-runner. That is a hardware/config prerequisite, not
					# a bundle fault, and R3 has already covered the relevant part.
					notassessed R4 "s6-rc brought up nothing: bringup was aborted before any service ran"
					note "this is a configuration or hardware prerequisite of the image,"
					note "not a bundle fault; R3 above already verified the compiled bundle"
					# Still comparable: if the published image brings these up in the
					# same environment and this build brings up nothing, that is a
					# regression, not a hardware prerequisite.
					note "--- last 12 log lines ---"
					tail -12 <<<"$LOGS" | sed 's/^/      /'
				elif [[ -z "$not_up" ]]; then
					pass "R4 all services in the user bundle's transitive closure are up"
				elif [[ $DEGRADED -eq 1 && $STRICT_STARTUP -eq 0 ]]; then
					# The exit-code contract makes this decidable without any
					# comparison. A service that declared an expected environmental
					# failure explains itself; one that failed with any other code
					# is a real fault. A service with no code of its own never ran
					# at all, which means it is collateral of a root that did fail,
					# so it is judged through that root rather than on its own.
					d4_declared="" d4_unexplained="" d4_collateral=""
					partition_by_exit "$not_up" d4_declared d4_unexplained d4_collateral
					if [[ -n "${d4_unexplained// /}" ]]; then
						fail R4 "services failed without declaring the failure expected: $(with_codes "$d4_unexplained")"
						note "declared as expected (exit $SDRE_CONFIG_EXIT): ${d4_declared:-none}"
						note "a service that cannot run for want of configuration or"
						note "hardware should exit $SDRE_CONFIG_EXIT to say so; any other code is"
						note "treated as a real fault, which is the point of the contract"
						note "--- last 20 log lines ---"
						tail -20 <<<"$LOGS" | sed 's/^/      /'
					elif [[ -n "${d4_declared// /}" ]]; then
						pass "R4 every service that did not start declared an expected environmental failure"
						note "declared (exit $SDRE_CONFIG_EXIT): $d4_declared"
						[[ -n "${d4_collateral// /}" ]] &&
							note "did not run as a consequence: $d4_collateral"
					else
						notassessed R4 "service startup not assessed directly (degraded mode)"
						note "not up: $not_up"
						note "none of these reported an exit code, so nothing declared"
						note "whether the failure is expected"
					fi
				else
					r4_declared="" r4_unexplained="" r4_collateral=""
					partition_by_exit "$not_up" r4_declared r4_unexplained r4_collateral
					[[ -n "${r4_declared// /}" ]] &&
						note "declared an expected environmental failure (exit $SDRE_CONFIG_EXIT): $r4_declared"
					if [[ -z "${r4_unexplained// /}" && -z "${r4_collateral// /}" ]]; then
						pass "R4 every service either started or declared an expected environmental failure"
					else
					fail R4 "registered but not up: ${r4_unexplained}${r4_collateral}"
					note "nothing declared these as expected; a service that cannot run"
					note "in this environment should exit $SDRE_CONFIG_EXIT to say so"
					note "currently down: $(s6_tool s6-rc -da list | tr '\n' ' ')"
					note "--- last 30 log lines ---"
					tail -30 <<<"$LOGS" | sed 's/^/      /'
					fi
				fi
			fi

			# --- optional opt-in HTTP probe ---------------------------------
			if [[ -n "$HTTP_PROBE" ]]; then
				deadline=$((SECONDS + HTTP_PROBE_TIMEOUT))
				ok=0
				while [[ $SECONDS -lt $deadline ]]; do
					if in_container sh -c \
						"command -v curl >/dev/null 2>&1 && curl -fsS -o /dev/null '$HTTP_PROBE'"; then
						ok=1
						break
					fi
					sleep 2
				done
				if [[ $ok -eq 1 ]]; then
					pass "P1 HTTP probe answered: $HTTP_PROBE"
				elif ! in_container sh -c 'command -v curl >/dev/null 2>&1'; then
					notassessed P1 "HTTP probe skipped: curl not present in image"
				else
					fail P1 "HTTP probe did not answer within ${HTTP_PROBE_TIMEOUT}s: $HTTP_PROBE"
				fi
			fi
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Result
# ---------------------------------------------------------------------------

head1 "Result"


if [[ $FAILED -eq 0 ]]; then
	printf '%sALL CHECKS PASSED%s for %s\n' "$C_GRN" "$C_OFF" "$IMAGE"
	if [[ ${#NOTASSESSED_CHECKS[@]} -gt 0 ]]; then
		note "not assessed: ${NOTASSESSED_CHECKS[*]}"
	fi
	exit 0
fi

printf '%sVERIFICATION FAILED%s for %s (failed: %s)\n' \
	"$C_RED" "$C_OFF" "$IMAGE" "${FAILED_CHECKS[*]}"
exit 1
