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
# The Dockerfile is read as logical instructions (continuation lines joined,
# comment lines inside an instruction skipped), and only the image references an
# instruction actually consumes are considered: FROM's image, COPY --from= and
# RUN --mount=...,from=, all in the flags before the command starts. Comments,
# LABELs, command text and heredoc bodies are never touched and never count.
# References already on the variant (<variant>-*, next, next-*) are left alone,
# so running this twice is harmless. Images outside <owner> are never touched.
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
# Fails when the variant is invalid, a reference is pinned by digest or built
# from a build argument, no SDR-E reference is consumed, or (with
# --verify-exists) a rewritten image does not exist.
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

# Handle an image reference the build consumes. SDR-E images are rewritten,
# other images and stage names are left alone, and anything that is only
# resolved at build time is refused because what it names cannot be checked.
# Result in NEW_REF.
consume_ref() {
	local ref="$1" what="$2"
	if [[ "$ref" == *'$'* ]]; then
		die "${what} '${ref}' uses a build argument; base_variant cannot tell which image it names. Write the image reference literally."
	fi
	if [[ "$ref" == "$PREFIX"* ]]; then
		rewrite_ref "$ref"
	else
		NEW_REF="$ref"
	fi
}

# Handle one token while still in an instruction's flag region: FROM's flags
# and image, COPY's --from=, RUN's --mount=...,from=. The first token that is
# not a flag ends the region; everything after it is payload and never touched.
# Result in NEW_TOKEN.
process_token() {
	local tok="$1" opts opt joined i
	NEW_TOKEN="$tok"

	if [[ "$tok" == --* ]]; then
		case "$INSTR" in
		COPY)
			if [[ "$tok" == --from=* ]]; then
				consume_ref "${tok#--from=}" "COPY --from"
				NEW_TOKEN="--from=${NEW_REF}"
			fi
			;;
		RUN)
			if [[ "$tok" == --mount=* ]]; then
				IFS=',' read -r -a opts <<<"${tok#--mount=}"
				joined=""
				for i in "${!opts[@]}"; do
					opt="${opts[$i]}"
					if [[ "$opt" == from=* ]]; then
						consume_ref "${opt#from=}" "RUN --mount from"
						opt="from=${NEW_REF}"
					fi
					if [[ "$i" -eq 0 ]]; then
						joined="$opt"
					else
						joined+=",${opt}"
					fi
				done
				NEW_TOKEN="--mount=${joined}"
			fi
			;;
		esac
		return
	fi

	if [[ "$INSTR" == "FROM" ]]; then
		consume_ref "$tok" "FROM"
		NEW_TOKEN="$NEW_REF"
	fi
	IN_FLAGS=false
}

echo "Applying base variant '${VARIANT}' to ${FILE}:" >&2

# Walk logical instructions: a trailing backslash continues an instruction, and
# comment or blank lines inside one are skipped (Docker drops them). Heredoc
# bodies are copied verbatim.
INSTR=""
IN_INSTR=false
IN_FLAGS=false
LEADING_COMMENTS=true
declare -a HEREDOCS=()
declare -a OUT=()
heredoc_re="^<<(-?)([\"']?)([A-Za-z_][A-Za-z0-9_]*)\\2$"

while IFS= read -r line || [[ -n "$line" ]]; do
	if [[ ${#HEREDOCS[@]} -gt 0 && "$IN_INSTR" == false ]]; then
		OUT+=("$line")
		term="${HEREDOCS[0]}"
		check="$line"
		if [[ "$term" == -* ]]; then
			term="${term#-}"
			check="${line#"${line%%[!$'\t']*}"}"
		fi
		if [[ "$check" == "$term" ]]; then
			HEREDOCS=("${HEREDOCS[@]:1}")
		fi
		continue
	fi

	if [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]]; then
		# Parser directives only count in the comment block at the very top.
		if [[ "$LEADING_COMMENTS" == true && "$line" =~ ^#[[:space:]]*escape[[:space:]]*=[[:space:]]*([^[:space:]]) ]]; then
			[[ "${BASH_REMATCH[1]}" == "\\" ]] || die "the '# escape=' parser directive is not supported with base_variant"
		fi
		OUT+=("$line")
		continue
	fi
	LEADING_COMMENTS=false

	content="$line"
	suffix=""
	continues=false
	if [[ "$line" =~ ^(.*)(\\[[:space:]]*)$ ]]; then
		content="${BASH_REMATCH[1]}"
		suffix="${BASH_REMATCH[2]}"
		continues=true
	fi

	out=""
	remaining="$content"
	if [[ "$IN_INSTR" == false ]]; then
		[[ "$content" =~ ^([[:space:]]*)([^[:space:]]+)(.*)$ ]]
		out="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"
		remaining="${BASH_REMATCH[3]}"
		INSTR="${BASH_REMATCH[2]^^}"
		case "$INSTR" in
		FROM | RUN | COPY | ADD) IN_FLAGS=true ;;
		*) IN_FLAGS=false ;;
		esac
	fi

	while [[ "$remaining" =~ ^([[:space:]]*)([^[:space:]]+)(.*)$ ]]; do
		ws="${BASH_REMATCH[1]}"
		tok="${BASH_REMATCH[2]}"
		remaining="${BASH_REMATCH[3]}"
		if [[ "$IN_FLAGS" == true ]]; then
			process_token "$tok"
			tok="$NEW_TOKEN"
		fi
		if [[ "$INSTR" =~ ^(RUN|COPY|ADD)$ && "$tok" =~ $heredoc_re ]]; then
			HEREDOCS+=("${BASH_REMATCH[1]}${BASH_REMATCH[3]}")
		fi
		out+="${ws}${tok}"
	done

	OUT+=("${out}${remaining}${suffix}")
	IN_INSTR="$continues"
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
