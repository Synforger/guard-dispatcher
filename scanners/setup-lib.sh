#!/usr/bin/env bash
# =============================================================================
# personal-template / shared bash primitives
# =============================================================================
# Source this file (= `source setup-lib.sh`) before using its helpers; do not
# execute it directly. All functions are POSIX bash 5.x and assume the caller
# has already `set -euo pipefail`.
#
# Exposed primitives:
#   load_versions [<path>]         Populate VERSION_<KEY>=<constraint> env
#                                  vars from the given versions.yaml (default
#                                  = repo-root .tooling/versions.yaml, falling
#                                  back to _core/.tooling/versions.yaml).
#   check_command <name>           Return 0 if <name> is on PATH, 1 otherwise.
#   get_version <name>             Print the binary's semver string to stdout.
#                                  Supports bash / git / python / node / rust /
#                                  swift / kotlin / cmake / dotnet (= cs).
#                                  Empty string on unknown tool / parse miss.
#   version_satisfies <actual> <constraint>
#                                  Return 0 if <actual> meets <constraint>.
#                                  Constraint forms: ">=X.Y[.Z]" (floor) and
#                                  "X.Y.Z" (exact pin).
#   log_info / log_ok / log_warn / log_fail
#                                  Coloured stderr output (auto-disabled when
#                                  stderr is not a TTY or NO_COLOR is set).
# =============================================================================

# ---- colour handling -------------------------------------------------------

if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    _LIB_C_RESET=$'\033[0m'
    _LIB_C_INFO=$'\033[36m'   # cyan
    _LIB_C_OK=$'\033[32m'     # green
    _LIB_C_WARN=$'\033[33m'   # yellow
    _LIB_C_FAIL=$'\033[31m'   # red
else
    _LIB_C_RESET="" _LIB_C_INFO="" _LIB_C_OK="" _LIB_C_WARN="" _LIB_C_FAIL=""
fi

log_info() { printf '%sinfo:%s %s\n' "${_LIB_C_INFO}" "${_LIB_C_RESET}" "$*" >&2; }
log_ok()   { printf '%sok:%s   %s\n' "${_LIB_C_OK}"   "${_LIB_C_RESET}" "$*" >&2; }
log_warn() { printf '%swarn:%s %s\n' "${_LIB_C_WARN}" "${_LIB_C_RESET}" "$*" >&2; }
log_fail() { printf '%sfail:%s %s\n' "${_LIB_C_FAIL}" "${_LIB_C_RESET}" "$*" >&2; }

# ---- versions.yaml loader --------------------------------------------------

# Resolves the versions.yaml path. Prefers the post-init layout
# (.tooling/versions.yaml) and falls back to the template-state path
# (_core/.tooling/versions.yaml). Returns 0 + prints the path on success,
# 1 on failure.
_resolve_versions_file() {
    local explicit="${1:-}"
    if [ -n "${explicit}" ]; then
        [ -f "${explicit}" ] && { printf '%s\n' "${explicit}"; return 0; }
        return 1
    fi
    if [ -f ".tooling/versions.yaml" ]; then
        printf '%s\n' ".tooling/versions.yaml"
        return 0
    fi
    if [ -f "_core/.tooling/versions.yaml" ]; then
        printf '%s\n' "_core/.tooling/versions.yaml"
        return 0
    fi
    return 1
}

# load_versions [<path>]
# Populates env vars of the form VERSION_<UPPER_KEY>=<constraint>.
load_versions() {
    local file
    if ! file="$(_resolve_versions_file "${1:-}")"; then
        log_fail "versions.yaml not found (looked in .tooling/ and _core/.tooling/)"
        return 1
    fi

    local line key val upper
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%%#*}"                                   # drop trailing inline comment
        line="$(printf '%s' "${line}" | sed -e 's/[[:space:]]*$//')"
        [ -z "${line}" ] && continue
        case "${line}" in
            [[:space:]]*) continue ;;                        # skip indented (= section body)
            \#*)          continue ;;
        esac
        key="${line%%:*}"
        val="${line#*:}"
        val="$(printf '%s' "${val}" | sed -e 's/^[[:space:]]*//' -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
        [ -z "${key}" ] || [ -z "${val}" ] && continue
        upper="$(printf '%s' "${key}" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
        eval "VERSION_${upper}=\"\${val}\""
        export "VERSION_${upper}"
    done < "${file}"

    log_info "loaded toolchain truth from ${file}"
}

# ---- command + version probing --------------------------------------------

check_command() { command -v "$1" >/dev/null 2>&1; }

# get_version <name>
# Prints the binary's semver string (= "X.Y" or "X.Y.Z"), empty on miss.
# Every probe runs under LANG=C / LC_ALL=C so localised binaries (= e.g.
# Homebrew bash outputs Japanese "バージョン" when LANG=ja_JP.UTF-8) still
# produce the English label form the regexes expect.
get_version() {
    local name="$1" out=""
    case "${name}" in
        bash)   out="$(LANG=C LC_ALL=C bash --version 2>/dev/null | head -1 | sed -nE 's/.*version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')" ;;
        git)    out="$(LANG=C LC_ALL=C git --version 2>/dev/null | sed -nE 's/.*git version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')" ;;
        python) out="$(LANG=C LC_ALL=C python3 --version 2>&1 | sed -nE 's/Python ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')" ;;
        node)   out="$(LANG=C LC_ALL=C node --version 2>/dev/null | sed -nE 's/^v?([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')" ;;
        rust)   out="$(LANG=C LC_ALL=C rustc --version 2>/dev/null | sed -nE 's/^rustc ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')" ;;
        swift)  out="$(LANG=C LC_ALL=C swift --version 2>/dev/null | head -1 | sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')" ;;
        kotlin) out="$(LANG=C LC_ALL=C kotlin -version 2>&1 | sed -nE 's/.*Kotlin version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p' | head -1)" ;;
        cmake)  out="$(LANG=C LC_ALL=C cmake --version 2>/dev/null | head -1 | sed -nE 's/cmake version ([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')" ;;
        cs|dotnet) out="$(LANG=C LC_ALL=C dotnet --version 2>/dev/null | sed -nE 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/p')" ;;
        *)      out="" ;;
    esac
    printf '%s' "${out}"
}

# binary_name <key>
# Maps a versions.yaml key to its executable name. Most are 1:1; cs uses
# dotnet, python uses python3.
binary_name() {
    case "$1" in
        cs)     echo "dotnet" ;;
        python) echo "python3" ;;
        *)      echo "$1" ;;
    esac
}

# ---- version comparison ----------------------------------------------------

# _semver_to_int <X.Y[.Z]> -> XXXYYYZZZ (zero-padded comparable integer)
_semver_to_int() {
    local v="$1"
    local IFS=.
    local parts=()
    # shellcheck disable=SC2206
    parts=(${v})
    local a="${parts[0]:-0}" b="${parts[1]:-0}" c="${parts[2]:-0}"
    printf '%d%03d%03d\n' "${a}" "${b}" "${c}"
}

# version_satisfies <actual> <constraint>
# Constraint forms: ">=X.Y[.Z]" (floor) and "X.Y.Z" (exact pin).
version_satisfies() {
    local actual="$1" constraint="$2"
    [ -z "${actual}" ] && return 1
    case "${constraint}" in
        ">="*)
            local floor="${constraint#>=}"
            [ "$(_semver_to_int "${actual}")" -ge "$(_semver_to_int "${floor}")" ]
            ;;
        *)
            [ "${actual}" = "${constraint}" ]
            ;;
    esac
}
