#!/usr/bin/env bash
#
# Self-test for verify-s6-services.sh.
#
# A test suite that only proved the happy path would not have caught the
# s6-overlay 3.2.3.1 regression, because the broken images built and ran fine.
# So the point of this script is the negative cases: each fixture is a container
# that is broken in a specific way, and the verifier must reject it for the
# specific reason stated. If the verifier ever stops detecting one of these, this
# fails.
#
# Usage: test_fixtures/run-selftest.sh
# Requires: docker, and the harness image built from the repo root Dockerfile.

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

VERIFY=".github/actions/verify-s6-services/verify-s6-services.sh"
SETTLE="${SETTLE_SECONDS:-8}"
rc_overall=0

pass() { printf '\033[0;32mok\033[0m    %s\n' "$*"; }
bad() {
	printf '\033[0;31mFAIL\033[0m  %s\n' "$*"
	rc_overall=1
}

# Indent captured output for readability without shelling out to sed.
indent_out() {
	while IFS= read -r line; do printf '        %s\n' "$line"; done <<<"$1"
}

# expect <fixture> <expected-exit> <must-match-regex-or-empty>
expect() {
	local fixture="$1" want_rc="$2" want_re="${3:-}"
	local tag="s6selftest:$fixture" out rc

	if ! docker build -q -t "$tag" "test_fixtures/$fixture" >/dev/null 2>&1; then
		bad "$fixture: fixture image failed to build"
		return
	fi

	out="$("$VERIFY" --image "$tag" --settle "$SETTLE" 2>&1)"
	rc=$?

	if [[ "$rc" -ne "$want_rc" ]]; then
		bad "$fixture: expected exit $want_rc, got $rc"
		indent_out "$out"
		return
	fi
	if [[ -n "$want_re" ]] && ! grep -Eq "$want_re" <<<"$out"; then
		bad "$fixture: exit $rc as expected, but output did not match /$want_re/"
		indent_out "$out"
		return
	fi
	pass "$fixture (exit $rc${want_re:+, matched /$want_re/})"
}

echo "Building the harness image the fixtures derive from..."
if ! docker build -q -t harness:local . >/dev/null 2>&1; then
	echo "could not build the harness image from the repo root Dockerfile" >&2
	exit 1
fi

echo
echo "== positive cases (must pass) =="
expect_positive() {
	local tag="$1" name="$2"
	local out rc
	out="$("$VERIFY" --image "$tag" --settle "$SETTLE" 2>&1)"
	rc=$?
	if [[ $rc -eq 0 ]]; then
		pass "$name (exit 0)"
	else
		bad "$name: expected exit 0, got $rc"
		indent_out "$out"
	fi
}
expect_positive harness:local "harness image with two healthy services"
expect base-like 0 'base image, service assertions not applicable'
# A base image ships s6-overlay and so can still poison its children with a
# legacy bundle directory; an image with no s6-overlay cannot. They must not be
# conflated, or the not-found error from s6-rc-db gets compared against the
# expected service set and produces a bogus R3 failure.
expect not-s6 0 'does not ship s6-overlay v3'

echo
echo "== negative cases (must be rejected, for the right reason) =="
# The populated legacy bundle is caught statically and by the log canary. Note it
# does NOT fail R3, because the shim compiled the legacy bundle and it happened to
# contain the same services -- which is exactly why S1 and R1 have to exist.
expect legacy-populated 1 'FAIL.*\[S1\].*deprecated bundle directory'
# The empty legacy bundle is the silent killer: the service set is simply dropped.
expect legacy-empty 1 'FAIL.*\[R3\].*compiled user bundle does NOT match'
expect unregistered 1 'FAIL.*\[S2\].*defined but NONE are registered'

echo
if [[ $rc_overall -eq 0 ]]; then
	printf '\033[0;32mSELF-TEST PASSED\033[0m\n'
else
	printf '\033[0;31mSELF-TEST FAILED\033[0m\n'
fi
exit "$rc_overall"
