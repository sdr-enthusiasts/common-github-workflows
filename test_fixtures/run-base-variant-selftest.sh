#!/usr/bin/env bash
#
# Self-test for apply-base-variant.sh.
#
# The rewrite decides which image a "next" build is really built on, and its
# worst failure is silent: a reference left on the stable tag still builds, and
# the result is published as if it were the next release. So besides checking the
# rewrites, every refusal case below must keep failing.
#
# Usage: test_fixtures/run-base-variant-selftest.sh
# Requires: bash only (no docker, no network).

set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

APPLY=".github/actions/apply-base-variant/apply-base-variant.sh"
FIXTURES="test_fixtures/base-variant"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
rc_overall=0

pass() { printf '\033[0;32mok\033[0m    %s\n' "$*"; }
bad() {
	printf '\033[0;31mFAIL\033[0m  %s\n' "$*"
	rc_overall=1
}

# rewrite <fixture> [extra args...]: output must equal <fixture>/expected, and a
# second run must change nothing.
rewrite() {
	local fixture="$1" file="$work/$1.Dockerfile" out
	shift
	cp "$FIXTURES/$fixture/input" "$file"

	if ! out="$("$APPLY" --variant forky --file "$file" "$@" 2>&1)"; then
		bad "$fixture: rewrite failed"
		printf '%s\n' "$out"
		return
	fi
	if ! diff -u "$FIXTURES/$fixture/expected" "$file"; then
		bad "$fixture: output differs from expected"
		return
	fi
	if ! "$APPLY" --variant forky --file "$file" "$@" >/dev/null 2>&1 ||
		! diff -q "$FIXTURES/$fixture/expected" "$file" >/dev/null; then
		bad "$fixture: second run was not a no-op"
		return
	fi
	pass "$fixture"
}

# refuse <name> <must-match-regex> <apply args...>: must exit non-zero, say why,
# and leave the Dockerfile untouched.
refuse() {
	local name="$1" want_re="$2" file="$work/refuse.Dockerfile" out
	shift 2
	cp "$work/refuse.src" "$file"

	if out="$("$APPLY" "$@" --file "$file" 2>&1)"; then
		bad "$name: expected failure, got success"
		printf '%s\n' "$out"
		return
	fi
	if ! grep -Eq "$want_re" <<<"$out"; then
		bad "$name: failed, but output did not match /$want_re/"
		printf '%s\n' "$out"
		return
	fi
	if ! diff -q "$work/refuse.src" "$file" >/dev/null; then
		bad "$name: Dockerfile was modified despite the failure"
		return
	fi
	pass "$name"
}

map() {
	local tag="$1" want="$2" got
	got="$("$APPLY" --variant forky --map-tag "$tag" 2>&1)"
	if [[ "$got" == "$want" ]]; then
		pass "map-tag $tag -> $want"
	else
		bad "map-tag $tag: expected '$want', got '$got'"
	fi
}

echo "Rewrites:"
for fixture in multi-stage child-images composed-test-redirect already-on-variant instruction-parsing; do
	rewrite "$fixture"
done
rewrite excluded-image --exclude acars-bridge

echo "Refusals:"
printf 'FROM ghcr.io/sdr-enthusiasts/docker-baseimage:base\n' >"$work/refuse.src"
refuse "uppercase variant" "lowercase Debian codename" --variant Forky
refuse "empty variant" "lowercase Debian codename" --variant ""
refuse "shell metacharacters" "lowercase Debian codename" --variant 'forky;rm'
refuse "tag-like variant" "lowercase Debian codename" --variant forky-base

printf 'FROM ghcr.io/sdr-enthusiasts/docker-baseimage:base@sha256:%s\n' "$(printf '0%.0s' {1..64})" >"$work/refuse.src"
refuse "digest-pinned reference" "pinned by digest" --variant forky

printf 'FROM debian:trixie-slim\nRUN echo ghcr.io/sdr-enthusiasts/docker-baseimage:base\n' >"$work/refuse.src"
refuse "no SDR-E references" "no ghcr.io/sdr-enthusiasts/" --variant forky

# References the build does not consume must not count as found.
printf 'FROM debian:trixie-slim\n# COPY --from=ghcr.io/sdr-enthusiasts/docker-baseimage:base /a /a\n' >"$work/refuse.src"
refuse "reference only in a comment" "no ghcr.io/sdr-enthusiasts/" --variant forky

printf 'FROM debian:trixie-slim\nRUN echo from=ghcr.io/sdr-enthusiasts/docker-baseimage:base\n' >"$work/refuse.src"
refuse "reference only in command text" "no ghcr.io/sdr-enthusiasts/" --variant forky

printf "ARG BASE=ghcr.io/sdr-enthusiasts/docker-baseimage:base\nFROM \$BASE\n" >"$work/refuse.src"
refuse "build argument in FROM" "uses a build argument" --variant forky

printf "FROM ghcr.io/sdr-enthusiasts/docker-baseimage:base\nCOPY --from=\${STAGE} /a /a\n" >"$work/refuse.src"
refuse "build argument in COPY --from" "uses a build argument" --variant forky

printf '# escape=`\nFROM ghcr.io/sdr-enthusiasts/docker-baseimage:base\n' >"$work/refuse.src"
refuse "escape directive" "escape=" --variant forky

printf 'FROM ghcr.io/sdr-enthusiasts/acars-bridge:latest\n' >"$work/refuse.src"
refuse "only excluded references" "no ghcr.io/sdr-enthusiasts/" --variant forky --exclude acars-bridge

printf 'FROM ghcr.io/sdr-enthusiasts/docker-baseimage:base\n' >"$work/refuse.src"
refuse "invalid exclude name" "invalid image name" --variant forky --exclude 'acars-bridge;rm'

echo "Published tag mapping:"
map latest next
map telegraf next-telegraf
map next next
map next-telegraf next-telegraf

exit "$rc_overall"
