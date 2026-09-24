#!/usr/bin/env bash
# =============================================================================
# Word-list -> PCRE alternation (the single place that parses anon-words.txt)
# =============================================================================
# Source this file; do not execute it. Both the pre-commit scanner and the
# deep audit build their pattern here, so a change to the list format can
# never reach one of them and miss the other.
#
#   build_anon_pattern <words-file>   Print the PCRE alternation to stdout.
#                                     Returns 1 when the list has no patterns.
#
# Line format:
#   <pattern>            # optional trailing comment
#   cs:<pattern>         # matched case-sensitively (see below)
#
# Callers wrap the result in `(?i)`, because a personal name has to be caught
# however it is capitalised. A few patterns are the opposite: their meaning
# depends on the capitalisation itself, and folding case makes them fire on
# unrelated text. The macOS home-root prefix is the live example — capitalised
# it is a filesystem path that carries a username, lowercased it is an
# ordinary URL segment used by any number of public websites. Such a pattern
# is prefixed `cs:` in the list and emitted as `(?-i:...)`, which turns case
# folding back off for that fragment alone.
# =============================================================================

build_anon_pattern() {
    local words_file="$1"
    local line fragments=()

    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line%%#*}"                               # drop comments
        line="$(printf '%s' "${line}" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "${line}" ] && continue
        if [ "${line#cs:}" != "${line}" ]; then
            line="(?-i:${line#cs:})"
        fi
        fragments+=("${line}")
    done < "${words_file}"

    [ "${#fragments[@]}" -eq 0 ] && return 1
    (IFS='|'; printf '%s\n' "${fragments[*]}")
}
