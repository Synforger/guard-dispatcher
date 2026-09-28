# Shared fixtures for the guard-dispatcher test suite.
#
# Every test gets a throwaway git repo under $BATS_TEST_TMPDIR and a
# sentinel-only word list, so no real operator data is ever touched and
# the suite runs identically on any machine.

GUARD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The sentinel the fixture word list flags. Deliberately gibberish so it
# can never collide with legitimate repo content.
SENTINEL="XLEAKX7q3z"

ALLOWED_EMAIL="synforger@users.noreply.github.com"
SYNFORGER_URL="git@github.com:Synforger/fixture-repo.git"
OTHER_URL="git@github.com:someone-else/fixture-repo.git"

setup_words() {
    export ANON_WORDS_FILE="${BATS_TEST_TMPDIR}/words.txt"
    printf '%s\n' "${SENTINEL}" > "${ANON_WORDS_FILE}"
    # The corpus scan reads the machine's private areas by default; a test must
    # never depend on (or build fingerprints of) the operator's real documents.
    export GUARD_CONFIG_DIR="${BATS_TEST_TMPDIR}/guard-config"
    export GUARD_CORPUS_CACHE="${BATS_TEST_TMPDIR}/guard-cache"
    # The corpus scan asks GitHub whether a destination is public. The fixture
    # remotes are answered from the cache so no test depends on the network.
    seed_visibility synforger/fixture-repo private
    seed_visibility someone-else/fixture-repo private
}

# seed_visibility <owner/repo> <public|private> — answer the corpus scan's
# visibility question for one repo without asking GitHub.
seed_visibility() {
    mkdir -p "${GUARD_CORPUS_CACHE}"
    python3 - "${GUARD_CORPUS_CACHE}/visibility.json" "$1" "$2" <<'PY'
import json, sys, time
path, slug, seen = sys.argv[1:]
try:
    known = json.load(open(path))
except (OSError, ValueError):
    known = {}
known[slug] = [seen, time.time()]
json.dump(known, open(path, "w"))
PY
}

# mk_repo <kind> — create a fixture repo and cd into it.
#   kind: synforger | other | no-remote
mk_repo() {
    local kind="$1"
    local dir="${BATS_TEST_TMPDIR}/repo-${kind}-${RANDOM}"
    git init -q "${dir}"
    cd "${dir}" || return 1
    git config user.email "${ALLOWED_EMAIL}"
    git config user.name "Fixture"
    git config commit.gpgsign false
    case "${kind}" in
        synforger) git remote add origin "${SYNFORGER_URL}" ;;
        other)     git remote add origin "${OTHER_URL}" ;;
        no-remote) : ;;
    esac
    echo "seed" > seed.txt
    git add seed.txt
    git -c core.hooksPath=/dev/null commit -q -m "seed"
}

# commit_bypassing_hooks <msg> — commit whatever is staged without any hooks
# (fixtures need to create "bad" history that the hooks would block).
commit_bypassing_hooks() {
    git -c core.hooksPath=/dev/null commit -q -m "$1"
}

run_pre_commit() { run bash "${GUARD_ROOT}/git-hooks/pre-commit"; }
run_commit_msg() { run bash "${GUARD_ROOT}/git-hooks/commit-msg" "$@"; }

# run_pre_push <stdin-line...> — feed ref lines to the pre-push dispatcher.
run_pre_push() {
    local input=""
    local line
    for line in "$@"; do
        input="${input}${line}
"
    done
    run bash -c "printf '%s' \"\$1\" | bash '${GUARD_ROOT}/git-hooks/pre-push' origin '${SYNFORGER_URL}'" _ "${input}"
}

# run_pre_push_to <url> <stdin-line...> — the same, pushing to a given remote URL.
run_pre_push_to() {
    local url="$1" input="" line
    shift
    for line in "$@"; do
        input="${input}${line}
"
    done
    run bash -c "printf '%s' \"\$1\" | bash '${GUARD_ROOT}/git-hooks/pre-push' origin \"\$2\"" _ "${input}" "${url}"
}

ZERO_SHA="0000000000000000000000000000000000000000"

# mk_office <path> <text> — a minimal Office document: a zip whose only XML part
# carries <text>. Real .pptx/.docx files are zips, so a scanner that reads the
# raw bytes sees compressed data and never the words.
mk_office() {
    local path="$1" text="$2" work
    work="$(mktemp -d "${BATS_TEST_TMPDIR}/office.XXXXXX")" || return 1
    mkdir -p "${work}/ppt/slides"
    printf '<?xml version="1.0"?><p:sld><a:t>%s</a:t></p:sld>\n' "${text}" \
        > "${work}/ppt/slides/slide1.xml"
    ( cd "${work}" && zip -q -r "${path}" . )
    rm -rf "${work}"
}

# mk_pdf <path> <text> [flate] — a one-page PDF whose text layer holds <text> (ASCII). With
# flate the page stream is compressed, as in a real PDF, so its bytes do not show the text.
mk_pdf() {
    python3 - "$1" "$2" "${3:-}" <<'PY'
import sys, zlib
path, text, flate = sys.argv[1], sys.argv[2], sys.argv[3] == "flate"
stream = f"BT /F1 10 Tf 20 700 Td ({text}) Tj ET".encode()
filt = b""
if flate:
    stream, filt = zlib.compress(stream), b" /Filter /FlateDecode"
objs = [b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        b"<< /Length %d%s >>\nstream\n" % (len(stream), filt) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
out, offsets = b"%PDF-1.4\n", []
for i, body in enumerate(objs, 1):
    offsets.append(len(out))
    out += b"%d 0 obj\n" % i + body + b"\nendobj\n"
xref = len(out)
out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objs) + 1)
out += b"".join(b"%010d 00000 n \n" % o for o in offsets)
out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objs) + 1, xref)
open(path, "wb").write(out)
PY
}
