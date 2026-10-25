#!/usr/bin/env bash
#
# Point a Dockerfile's SDR-E image references at the next-Debian-release images.
#
# Given a base variant (a Debian codename such as "forky"), every
# ghcr.io/<owner>/<image>:<tag> reference that a build consumes -- the image
# after FROM, or after from= in COPY --from= and RUN --mount=...,from= -- is
# rewritten:
#
#   docker-baseimage:<tag>   -> docker-baseimage:<variant>-<tag>
#   <any other image>:latest -> <image>:next
#   <any other image>:<tag>  -> <image>:next-<tag>
#
# The base images carry the codename so one release's base is never mistaken for
# another's. Everything built on top of them is published under the
# codename-free "next" channel, so the tag users pin to survives Debian releases.
# --map-tag applies the same rule to a published tag, so the workflow names its
# output with exactly the logic used for its inputs.
#
# References already on the variant (<variant>-*, next, next-*) are left alone,
# so running this twice is harmless. References anywhere else (LABEL, echo,
# comments) and images outside <owner> are never touched.
#
# --exclude names images that do not depend on the Debian release (for example
# acars-bridge, a static binary in a FROM scratch image) and so have no next
# variant; their references are left exactly as written. Everything else is
# rewritten by default, because forgetting to exclude an image fails loudly,
# whereas forgetting to include one would silently build on a stable image.
#
# Usage:
#   apply-base-variant.sh --variant <codename> --file <Dockerfile> [--owner <owner>]
#                         [--exclude <image>[,<image>...]] [--verify-exists]
#   apply-base-variant.sh --variant <codename> --map-tag <tag>
#
# Fails when the variant is invalid, a reference is pinned by digest, no SDR-E
# reference is found, or (with --verify-exists) a rewritten image does not exist.
# Each of those would otherwise produce an image that claims to be built on the
# next release but is not.

set -euo pipefail

VARIANT=""
FILE=""
OWNER="sdr-enthusiasts"
MAP_TAG=""
EXCLUDE=""
VERIFY_EXISTS=false

die() {
	echo "::error title=apply-base-variant::$*" >&2
	exit 1
}

while [[ $# -gt 0 ]]; do
	case "$1" in
	--variant)
		VARIANT="${2-}"
		shift 2
		;;
	--file)
		FILE="${2-}"
		shift 2
		;;
	--owner)
		OWNER="${2-}"
		shift 2
		;;
	--map-tag)
		MAP_TAG="${2-}"
		shift 2
		;;
	--exclude)
		EXCLUDE="${2-}"
		shift 2
		;;
	--verify-exists)
		VERIFY_EXISTS=true
		shift
		;;
	*) die "unknown argument: $1" ;;
	esac
done

# The value lands in image tags, so allow only a bare codename.
if [[ ! "$VARIANT" =~ ^[a-z][a-z0-9]*$ ]]; then
	die "base variant must be a lowercase Debian codename (letters and digits), got '${VARIANT}'"
fi

# Child-image rule, shared by input references and the published tag.
# Result in NEXT_TAG.
next_tag() {
	local tag="$1"
	if [[ "$tag" == "next" || "$tag" == next-* ]]; then
		NEXT_TAG="$tag"
	elif [[ "$tag" == "latest" ]]; then
		NEXT_TAG="next"
	else
		NEXT_TAG="next-${tag}"
	fi
}

if [[ -n "$MAP_TAG" ]]; then
	next_tag "$MAP_TAG"
	echo "$NEXT_TAG"
	exit 0
fi

[[ -n "$FILE" ]] || die "--file is required"
[[ -f "$FILE" ]] || die "Dockerfile not found: $FILE"
[[ "$OWNER" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "invalid owner '${OWNER}'"

declare -A EXCLUDED=()
IFS=', ' read -r -a exclude_list <<<"$EXCLUDE"
for name in "${exclude_list[@]}"; do
	[[ -n "$name" ]] || continue
	[[ "$name" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || die "invalid image name in exclude list: '${name}'"
	EXCLUDED[$name]=1
done

PREFIX="ghcr.io/${OWNER}/"
PREFIX_RE="ghcr\\.io/${OWNER}/"
# A reference ends at whitespace, a comma (mount options) or a quote.
REF_RE="${PREFIX_RE}[^[:space:],\"']+"
RE_FROM="^([[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]+(--platform=[^[:space:]]+[[:space:]]+)?)(${REF_RE})(.*)$"
RE_EQ="^(.*[Ff][Rr][Oo][Mm]=)(${REF_RE})(.*)$"

declare -A SEEN=()
declare -a TARGETS=()

# Result in NEW_REF.
rewrite_ref() {
	local ref="$1" rest name tag new_tag
	rest="${ref#"$PREFIX"}"
	name="${rest%%[:@]*}"

	if [[ -n "${EXCLUDED[$name]+x}" ]]; then
		NEW_REF="$ref"
		echo "  $ref (excluded, left as is)" >&2
		return
	fi

	if [[ "$rest" == *@* ]]; then
		die "'$ref' is pinned by digest; the digest would keep it on the stable image. Pin by tag to use a base variant."
	fi
	if [[ "$rest" == *:* ]]; then
		tag="${rest#*:}"
	else
		tag="latest"
	fi

	if [[ "$name" == "docker-baseimage" ]]; then
		if [[ "$tag" == "${VARIANT}-"* ]]; then
			new_tag="$tag"
		else
			new_tag="${VARIANT}-${tag}"
		fi
	else
		next_tag "$tag"
		new_tag="$NEXT_TAG"
	fi

	NEW_REF="${PREFIX}${name}:${new_tag}"
	if [[ "$NEW_REF" != "$ref" ]]; then
		echo "  $ref -> $NEW_REF" >&2
	else
		echo "  $ref (already on the variant)" >&2
	fi
	if [[ -z "${SEEN[$NEW_REF]+x}" ]]; then
		SEEN[$NEW_REF]=1
		TARGETS+=("$NEW_REF")
	fi
}

# Result in NEW_LINE.
rewrite_line() {
	local line="$1" head ref tail done_part=""

	if [[ "$line" =~ $RE_FROM ]]; then
		head="${BASH_REMATCH[1]}"
		ref="${BASH_REMATCH[3]}"
		tail="${BASH_REMATCH[4]}"
		rewrite_ref "$ref"
		line="${head}${NEW_REF}${tail}"
	fi

	# The greedy (.*) finds the last from= on the line; peel them off right to left.
	while [[ "$line" =~ $RE_EQ ]]; do
		head="${BASH_REMATCH[1]}"
		ref="${BASH_REMATCH[2]}"
		tail="${BASH_REMATCH[3]}"
		rewrite_ref "$ref"
		done_part="${NEW_REF}${tail}${done_part}"
		line="$head"
	done

	NEW_LINE="${line}${done_part}"
}

echo "Applying base variant '${VARIANT}' to ${FILE}:" >&2

declare -a OUT=()
while IFS= read -r line || [[ -n "$line" ]]; do
	rewrite_line "$line"
	OUT+=("$NEW_LINE")
done <"$FILE"

if [[ ${#TARGETS[@]} -eq 0 ]]; then
	die "no ${PREFIX}* image references found in ${FILE}; a base variant build would be identical to the stable build"
fi

printf '%s\n' "${OUT[@]}" >"$FILE"

if [[ "$VERIFY_EXISTS" == true ]]; then
	missing=0
	for ref in "${TARGETS[@]}"; do
		if docker buildx imagetools inspect "$ref" >/dev/null 2>&1; then
			echo "  exists: $ref" >&2
		else
			echo "::error title=apply-base-variant::$ref does not exist; publish it before building on the '${VARIANT}' base variant" >&2
			missing=1
		fi
	done
	[[ "$missing" -eq 0 ]] || exit 1
fi

echo "--- image references after rewrite ---" >&2
grep -nE "^[[:space:]]*[Ff][Rr][Oo][Mm][[:space:]]|[Ff][Rr][Oo][Mm]=" "$FILE" >&2 || true
