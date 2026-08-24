#!/usr/bin/env bash
# Shared library for dependency management (sourced by dep scripts)

# --- Dependency ledger loader -------------------------------------------------
# Single source of truth for dep versions is deps.json (see docs/.../specs).
# dep_source resolves override-for-this-FFmpeg-major else default; clone_dep clones it.
_ledger_path() { printf '%s' "${LEDGER:-${ROOT_DIR}/deps.json}"; }
_ffmpeg_major() { printf '%s' "${FFMPEG_VERSION%%.*}"; }

# dep_source <name> -> "<origin>\t<tag|branch|commit>\t<refval>"
# Resolution precedence: overrides[major][name] wins over defaults[name] — but a
# platform-scoped override (one carrying a "platforms" list) applies ONLY when the
# build's BUILD_RID is in that list; on any other RID it falls through to the default.
# An override without "platforms" applies to every RID for that FFmpeg major.
dep_source() {
  local name="$1" ledger major rid entry origin reftype refval
  ledger="$(_ledger_path)"; major="$(_ffmpeg_major)"; rid="${BUILD_RID:-}"
  command -v jq >/dev/null 2>&1 || { echo "dep_source: jq not found (build prerequisite)" >&2; return 2; }
  [ -f "${ledger}" ] || { echo "dep_source: ledger not found: ${ledger}" >&2; return 2; }
  entry="$(jq -c --arg m "${major}" --arg n "${name}" --arg r "${rid}" '
            (.overrides[$m][$n]) as $ov
            | (if ($ov != null) and (($ov.platforms == null) or ($ov.platforms | index($r)))
               then $ov else .defaults[$n] end)
            // empty' "${ledger}")" || return 2
  [ -n "${entry}" ] || { echo "dep_source: '${name}' not in ledger (defaults or overrides.${major})" >&2; return 2; }
  local nrefs; nrefs="$(jq -r '[.tag,.branch,.commit]|map(select(.!=null))|length' <<<"${entry}")"
  [ "${nrefs}" = "1" ] || { echo "dep_source: '${name}' malformed (need exactly one of tag/branch/commit, found ${nrefs})" >&2; return 2; }
  origin="$(jq -r '.origin // empty' <<<"${entry}")"
  reftype="$(jq -r 'to_entries | map(select(.key=="tag" or .key=="branch" or .key=="commit")) | .[0].key // empty' <<<"${entry}")"
  refval="$(jq -r --arg k "${reftype}" '.[$k] // empty' <<<"${entry}")"
  { [ -n "${origin}" ] && [ -n "${reftype}" ] && [ -n "${refval}" ]; } \
    || { echo "dep_source: '${name}' malformed (need origin + exactly one of tag/branch/commit)" >&2; return 2; }
  printf '%s\t%s\t%s\n' "${origin}" "${reftype}" "${refval}"
}

# clone_dep <name> <destdir> -> shallow clone + checkout the resolved ref
clone_dep() {
  local name="$1" dest="$2" origin reftype refval out
  out="$(dep_source "${name}")" || return $?
  IFS=$'\t' read -r origin reftype refval <<<"${out}"
  echo "clone_dep: ${name} <- ${origin} @ ${reftype}:${refval}"
  case "${reftype}" in
    tag|branch) git clone --depth 1 --branch "${refval}" "${origin}" "${dest}" ;;
    commit)     git clone "${origin}" "${dest}" && git -C "${dest}" checkout --detach "${refval}" ;;
    *)          echo "clone_dep: bad reftype '${reftype}'" >&2; return 2 ;;
  esac
}

# dep_version <name> -> prints the resolved ref value only (tag/branch/commit string)
dep_version() {
  local origin reftype refval
  IFS=$'\t' read -r origin reftype refval < <(dep_source "$1") || return $?
  printf '%s\n' "${refval}"
}
