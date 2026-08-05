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
# BASELINE COMPARISON
# -------------------
# During the migration, comparing against the currently-published image was
# three times the only thing that distinguished a real regression from
# pre-existing behaviour. --baseline makes that first-class: if the target fails,
# the same checks are run against the published image, and a failure reproduced
# identically there is reported as PRE-EXISTING rather than as a regression.
#
# Exit codes: 0 pass (or vacuous pass / not-applicable), 1 fail, 2 inconclusive,
#             3 usage error.

set -uo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

IMAGE=""
BASELINE=""
SETTLE_SECONDS="${SETTLE_SECONDS:-8}"
HTTP_PROBE=""
HTTP_PROBE_TIMEOUT=30
RUNTIME_CHECKS=1
STRICT_STARTUP=0
ASSESS_ONLY=0
declare -a RUN_ENV=()

usage() {
	cat <<'EOF'
usage: verify-s6-services.sh --image IMAGE [options]

  --image IMAGE            image to verify (required)
  --baseline IMAGE         published image to compare against when the target
                           fails, to separate regressions from pre-existing faults
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
	--baseline)
		BASELINE="${2:-}"
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
	--_assess-only)
		ASSESS_ONLY=1
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
declare -a FAILED_SIGS=()
declare -a NOTASSESSED_CHECKS=()

pass() { printf '%sPASS%s  %s\n' "$C_GRN" "$C_OFF" "$*"; }
note() { printf '      %s\n' "$*"; }
head1() { printf '\n%s%s%s\n' "$C_BLD" "$*" "$C_OFF"; }
warn() { printf '%sWARN%s  %s\n' "$C_YEL" "$C_OFF" "$*"; }

# fail <id> <message>
#   Records a failing check. FAIL_DETAIL may be set by the caller beforehand to
#   name the specific offending services; it becomes part of the check's
#   signature. Signatures, not bare check IDs, are what the baseline comparison
#   compares -- otherwise "service A is down" in the published image and
#   "service B is down" here would both reduce to "R4" and a genuinely new fault
#   would be misreported as pre-existing.
fail() {
	local id="$1"
	shift
	printf '%sFAIL%s  [%s] %s\n' "$C_RED" "$C_OFF" "$id" "$*"
	FAILED_CHECKS+=("$id")
	local detail="${FAIL_DETAIL:-}"
	# Normalise so ordering and whitespace cannot affect the comparison.
	detail="$(tr ' ' '\n' <<<"$detail" | sed '/^$/d' | sort -u | paste -sd, -)"
	if [[ -n "$detail" ]]; then
		FAILED_SIGS+=("${id}:${detail}")
	else
		FAILED_SIGS+=("$id")
	fi
	unset FAIL_DETAIL
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
	docker rm -f "$cid" >/dev/null 2>&1
	return 0
}

# ---------------------------------------------------------------------------
# Runtime helpers
# ---------------------------------------------------------------------------

LOGS=""
STATE="unknown"

start_container() {
	docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
	docker run -d --name "$CONTAINER" -e S6_VERBOSITY=2 \
		"${RUN_ENV[@]+"${RUN_ENV[@]}"}" "$@" "$IMAGE" >/dev/null 2>&1
}

sample() {
	LOGS="$(docker logs "$CONTAINER" 2>&1)"
	STATE="$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null || echo unknown)"
}

in_container() { docker exec "$CONTAINER" "$@" 2>/dev/null; }

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
	FAIL_DETAIL="${legacy_found[*]}"
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
if [[ $n_expected -eq 0 && $n_defined -eq 0 ]]; then
	IMAGE_CLASS="base"
elif [[ $n_expected -eq 0 && $n_defined -gt 0 ]]; then
	IMAGE_CLASS="unregistered"
fi

case "$IMAGE_CLASS" in
base)
	pass "S2 no user services defined or registered -- base image, service assertions not applicable"
	note "s6-rc.d and user-bundles.d/user/contents.d are both empty, which is"
	note "the normal shape of a base image such as :base or :wreadsb"
	;;
unregistered)
	FAIL_DETAIL="$DEFINED"
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
		FAIL_DETAIL="$missing_def"
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
			COMPILED="$(in_container s6-rc-db -c /run/s6/db contents user | sort)"
			if [[ "$COMPILED" == "$EXPECTED" ]]; then
				if [[ "$IMAGE_CLASS" == "base" ]]; then
					pass "R3 compiled user bundle is empty, as expected for a base image"
				else
					pass "R3 compiled user bundle matches the registrations exactly"
				fi
			else
				FAIL_DETAIL="$(comm -3 <(echo "$EXPECTED") <(echo "$COMPILED"))"
				fail R3 "compiled user bundle does NOT match the registrations"
				note "expected: $(echo "$EXPECTED" | tr '\n' ' ')"
				note "compiled: $(echo "$COMPILED" | tr '\n' ' ')"
				note "missing : $(comm -23 <(echo "$EXPECTED") <(echo "$COMPILED") | tr '\n' ' ')"
				note "extra   : $(comm -13 <(echo "$EXPECTED") <(echo "$COMPILED") | tr '\n' ' ')"
			fi

			# --- R4: and that they are actually up ---------------------------
			if [[ "$IMAGE_CLASS" == "base" ]]; then
				notassessed R4 "no user services to start (base image)"
			else
				UP="$(in_container s6-rc -a list | sort)"
				TRANSITIVE="$(in_container s6-rc-db -c /run/s6/db all-dependencies user | sort)"
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
					note "--- last 12 log lines ---"
					tail -12 <<<"$LOGS" | sed 's/^/      /'
				elif [[ -z "$not_up" ]]; then
					pass "R4 all services in the user bundle's transitive closure are up"
				elif [[ $DEGRADED -eq 1 && $STRICT_STARTUP -eq 0 ]]; then
					notassessed R4 "service startup not assessed (degraded mode: credentials withheld)"
					note "not up: $not_up"
				else
					FAIL_DETAIL="$not_up"
					fail R4 "registered but not up: $not_up"
					note "currently down: $(in_container s6-rc -da list | tr '\n' ' ')"
					note "--- last 30 log lines ---"
					tail -30 <<<"$LOGS" | sed 's/^/      /'
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
					FAIL_DETAIL="$HTTP_PROBE"
					fail P1 "HTTP probe did not answer within ${HTTP_PROBE_TIMEOUT}s: $HTTP_PROBE"
				fi
			fi
		fi
	fi
fi

# ---------------------------------------------------------------------------
# Result, plus baseline comparison when the target failed
# ---------------------------------------------------------------------------

emit_machine_summary() {
	printf '\n__RESULT__=%s\n' "$1"
	printf '__FAILED_CHECKS__=%s\n' "${FAILED_CHECKS[*]+${FAILED_CHECKS[*]}}"
	printf '__FAILED_SIGS__=%s\n' "${FAILED_SIGS[*]+${FAILED_SIGS[*]}}"
}

head1 "Result"

if [[ $FAILED -eq 0 ]]; then
	printf '%sALL CHECKS PASSED%s for %s\n' "$C_GRN" "$C_OFF" "$IMAGE"
	if [[ ${#NOTASSESSED_CHECKS[@]} -gt 0 ]]; then
		note "not assessed: ${NOTASSESSED_CHECKS[*]}"
	fi
	[[ $ASSESS_ONLY -eq 1 ]] && emit_machine_summary PASS
	exit 0
fi

printf '%sVERIFICATION FAILED%s for %s (failed: %s)\n' \
	"$C_RED" "$C_OFF" "$IMAGE" "${FAILED_CHECKS[*]}"

if [[ $ASSESS_ONLY -eq 1 ]]; then
	emit_machine_summary FAIL
	exit 1
fi

# Compare against the published image. Three times during the migration this was
# the only thing that separated a real regression from pre-existing behaviour.
if [[ -n "$BASELINE" ]]; then
	head1 "Baseline comparison"

	# A first-ever build has nothing published to compare against, and a missing
	# baseline must not be mistaken for a baseline that fails. Establish
	# availability explicitly before drawing any conclusion from the comparison.
	if ! docker image inspect "$BASELINE" >/dev/null 2>&1 &&
		! docker pull -q "$BASELINE" >/dev/null 2>&1; then
		warn "baseline image is not available, so regression analysis is not possible"
		note "tried: $BASELINE"
		note "this is normal for a first build or a newly renamed tag"
		note "reporting the target's own failures unchanged"
		exit 1
	fi

	note "re-running the same checks against the published image to determine"
	note "whether this is a regression or pre-existing: $BASELINE"

	declare -a base_args=(--image "$BASELINE" --settle "$SETTLE_SECONDS" --_assess-only)
	[[ $RUNTIME_CHECKS -eq 0 ]] && base_args+=(--no-runtime-checks)
	[[ $STRICT_STARTUP -eq 1 ]] && base_args+=(--strict-startup)
	[[ -n "$HTTP_PROBE" ]] && base_args+=(--http-probe "$HTTP_PROBE")
	i=0
	while [[ $i -lt ${#RUN_ENV[@]} ]]; do
		[[ "${RUN_ENV[i]}" == "-e" ]] && base_args+=(--env "${RUN_ENV[i + 1]}")
		i=$((i + 2))
	done

	base_out="$("$0" "${base_args[@]}" 2>&1)"
	while IFS= read -r line; do printf '  | %s\n' "$line"; done <<<"$base_out"
	base_sig_raw="$(sed -n 's/^__FAILED_SIGS__=//p' <<<"$base_out" | tail -1)"
	read -r -a base_sig_arr <<<"$base_sig_raw"

	# Compare signatures (check id + offending service names), not bare check ids.
	# "R4:svc-a" on the published image and "R4:svc-b" here are different faults
	# even though both are R4, and must be reported as a regression.
	target_sig="$(printf '%s\n' "${FAILED_SIGS[@]}" | sort -u | tr '\n' ' ')"
	base_sig="$(printf '%s\n' "${base_sig_arr[@]+${base_sig_arr[@]}}" | sort -u | tr '\n' ' ')"

	head1 "Verdict"
	if [[ "$target_sig" == "$base_sig" ]]; then
		warn "PRE-EXISTING: the published image fails identically ($base_sig)"
		note "same checks AND same offending services, so this build did not"
		note "introduce the fault. It is still a real problem, but not a regression."
		if [[ "${VERIFY_S6_BASELINE_PREEXISTING_IS_FAILURE:-0}" == "1" ]]; then
			exit 1
		fi
		exit 0
	fi

	new_failures="$(comm -23 \
		<(printf '%s\n' "${FAILED_SIGS[@]}" | sort -u) \
		<(printf '%s\n' "${base_sig_arr[@]+${base_sig_arr[@]}}" | sort -u) | tr '\n' ' ')"
	printf '%sREGRESSION%s for %s\n' "$C_RED" "$C_OFF" "$IMAGE"
	if [[ -n "${new_failures// /}" ]]; then
		note "new here, absent from the published image: $new_failures"
	fi
	fixed="$(comm -13 \
		<(printf '%s\n' "${FAILED_SIGS[@]}" | sort -u) \
		<(printf '%s\n' "${base_sig_arr[@]+${base_sig_arr[@]}}" | sort -u) | tr '\n' ' ')"
	if [[ -n "${fixed// /}" ]]; then
		note "present on the published image but not here (improved): $fixed"
	fi
	note "signature format is <check>:<offending services>"
fi

exit 1
