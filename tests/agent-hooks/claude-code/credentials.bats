#!/usr/bin/env bats
# agent-hooks/claude-code/credentials.py (through area-guard.py) — an agent's call that changes a
# password, a PIN, a key, a token or a login is held for the operator's yes to that very call;
# a call that only looks passes.
#
# A throwaway HOME with no areas; a made-up transcript holds what the agent showed and what the
# operator answered.

load ../../_internal/helpers
load ../../_internal/transcript

HOOK="${GUARD_ROOT}/agent-hooks/claude-code/area-guard.py"

setup() {
    H="$(cd -P "${BATS_TEST_TMPDIR}" && pwd)/home"
    mkdir -p "${H}/work" "${H}/.ssh"
    export HOME="${H}"
    export GUARD_CONFIG_DIR="${H}/.config/guard"
    export GUARD_CORPUS_CACHE="${H}/.cache/guard-corpus"
    export AREA_GUARD_STATE="${H}/state"
    unset GIT_CONFIG_GLOBAL GUARD_WORK_FOLDER GUARD_TAB_BINDINGS AGENT_PLATFORM_ROOT
    mkdir -p "${GUARD_CONFIG_DIR}"
    printf '%s\n' '送信して' '!も' '!いい' '!ない' '!る' '!た' > "${GUARD_CONFIG_DIR}/orders.txt"
    T="${H}/.claude/projects/work/s1.jsonl"
    mkdir -p "$(dirname "${T}")"
    : > "${T}"
    PROMPT=0
}

call() {
    local event
    event="$(jq -n --arg t "$1" --argjson i "$2" --arg c "${H}/work" --arg p "${T}" --arg q "p${PROMPT}" --arg u "${3:-toolu_1}" \
        '{session_id: "s1", tool_name: $t, tool_input: $i, cwd: $c, hook_event_name: "PreToolUse",
          transcript_path: $p, prompt_id: $q, tool_use_id: $u}')"
    run python3 "${HOOK}" <<< "${event}"
}
bash_call() { call Bash "$(jq -n --arg c "$1" '{command: $c}')" "${2:-toolu_1}"; }
write_to() { call Write "$(jq -n --arg f "$1" '{file_path: $f, content: "x"}')"; }
shown() { replied "$(printf 'May I run this?\n\n```guard\ntool: Bash\ncommand:\n%s\n```\n' "$1")"; }

passed() { [ "${status}" -eq 0 ] && [ -z "${output}" ]; }
held() { [ "${status}" -eq 0 ] && [[ "${output}" == *'"permissionDecision": "deny"'* ]] \
    && [[ "${output}" == *"does not change how the operator signs in"* ]]; }

# Each line: a command that changes how the operator signs in, one of every kind.
CHANGES=(
    "passwd"
    "dscl . -passwd someone newpass"
    "sysadminctl -resetPasswordFor me -newPassword x"
    "pwpolicy -u me -setpolicy newPasswordRequired=1"
    "security set-keychain-password login.keychain"
    "security add-generic-password -s svc -a me -w x"
    "security delete-internet-password -s github.com"
    "security list-keychains -s a.keychain"
    "security authorizationdb write system.login.console allow"
    "fdesetup changerecovery -personal"
    "diskutil apfs changePassphrase disk3s1 -user me"
    "bioutil -w -u 0"
    "defaults write com.apple.loginwindow autoLoginUser me"
    "kinit me@EXAMPLE.COM"
    "ssh-keygen -t ed25519 -f ~/.ssh/id_new"
    "ssh-keygen -p -f ~/.ssh/id_ed25519"
    "ssh-keygen -R example.com"
    "ssh-add --apple-use-keychain ~/.ssh/id_ed25519"
    "ssh-copy-id me@example.com"
    "gpg --full-generate-key"
    "gpg --change-passphrase me"
    "openssl genrsa -out key.pem 2048"
    "openssl rsa -in key.pem -aes256 -out key2.pem"
    "openssl rsa -in key.pem -passin stdin -out plain.pem"
    "age-keygen -o key.txt"
    "wg genkey"
    "git credential approve"
    "git credential-osxkeychain erase"
    "git config --global credential.helper osxkeychain"
    "git -C repo config --unset credential.helper"
    "gh auth login --hostname github.com"
    "gh auth refresh -s admin:org"
    "gh auth --hostname github.com login"
    "gh auth --hostname=github.com login"
    "gh auth switch"
    "gh auth setup-git"
    "gh secret set API_TOKEN"
    "gh ssh-key add ~/.ssh/id_ed25519.pub"
    "gh api user/keys -f key=ssh-ed25519"
    "tailscale login"
    "tailscale logout"
    "tailscale up --auth-key=tskey-abc"
    "tailscale lock sign nodekey:abc"
    "tailscale cert example.ts.net"
    "npm login"
    "npm token create"
    "npm config set //registry.npmjs.org/:_authToken abc"
    "npx vercel login"
    "pnpm dlx wrangler secret put API_TOKEN"
    "docker login ghcr.io"
    "gcloud auth login"
    "gcloud iam service-accounts keys create key.json"
    "aws configure"
    "aws iam create-access-key"
    "kubectl create secret generic db"
    "kubectl config set-credentials me"
    "claude setup-token"
    "codex login"
    "op item edit github"
    "pass insert github"
    "htpasswd -c users me"
    "poetry config pypi-token.pypi abc"
    "ngrok config add-authtoken abc"
    "direnv exec . gh auth login"
    "arch -arm64 gh auth login"
    "script -q /dev/null gh auth login"
    "op run -- gh auth login"
    "launchctl asuser 501 gh auth login"
    "su - someone -c 'passwd'"
    "ssh other-mac 'tailscale logout'"
    "ssh -p 22 other-mac gh auth login"
    "tmux send-keys -t 1 'passwd' Enter"
    "expect -c 'spawn passwd'"
    "osascript -e 'do shell script \"passwd\"'"
    "rm -f ~/.ssh/id_ed25519"
    "rm -rf ~/.ssh"
    "rm -rf ~/.gnupg"
    "trash ~/.ssh/id_ed25519"
    "unlink ~/.netrc"
    "mv ~/.config/gh/hosts.yml ~/.config/gh/hosts.yml.bak"
    "chmod 644 ~/.ssh/id_ed25519"
    "curl -X POST https://api.github.com/user/keys -d @k.json"
    "git remote set-url origin https://user:tok@github.com/o/r"
    "vercel env add SECRET production"
    "launchctl setenv ANTHROPIC_API_KEY x"
    "printf x > ~/.claude-work/.credentials.json"
)

# Each line: a command that only looks, beside the ones above.
LOOKS=(
    "security find-generic-password -s svc -w"
    "security list-keychains"
    "fdesetup status"
    "sysadminctl -secureTokenStatus me"
    "dscl . -read someone"
    "diskutil list"
    "defaults read com.apple.dock"
    "klist"
    "ssh-keygen -lf ~/.ssh/id_ed25519.pub"
    "ssh-keygen -y -f ~/.ssh/id_ed25519"
    "ssh-add -l"
    "gpg --list-keys"
    "openssl x509 -in cert.pem -text"
    "wg show"
    "git credential fill"
    "git config --get credential.helper"
    "git config user.name me"
    "git commit -m 'login page'"
    "gh auth status"
    "gh auth token"
    "gh secret list"
    "gh api user/keys"
    "gh pr list"
    "tailscale status"
    "tailscale up"
    "tailscale lock status"
    "tailscale serve 8080"
    "npm token list"
    "npm config get registry"
    "npm install"
    "gcloud auth list"
    "aws configure list"
    "aws s3 ls"
    "docker ps"
    "kubectl get pods"
    "op item get github"
    "pass show github"
    "echo login"
    "grep -rn 'gh auth login' docs"
    "cargo build"
    "uv run pytest"
    "gh pr list --search login"
    "gh pr create --title login --body x"
    "claude -p 'login'"
    "gh search issues token reset"
    "docker run --rm img token create"
    "gh label create secret"
    "uv add secret"
    "cargo add secret"
    "npm config set auth-type legacy"
    "chpass -s /bin/zsh"
    "gh --repo o/r pr list"
    "ssh other-mac uptime"
    "rm -f ~/.ssh/known_hosts.old"
    "mv ~/.ssh/config ~/.ssh/config.bak"
    "chmod 600 ~/notes.md"
    "curl https://api.github.com/user/keys"
    "git remote set-url origin https://github.com/o/r"
    "launchctl setenv PATH /usr/bin"
    "direnv allow"
    "rm ~/.claude.json.bak"
    "gh auth --hostname github.com status"
)

# judged <command>... — the hook's credential_change on each command, in one process: `held` or
# `passes`, a tab, the command. The tables are judged this way; the hook's own refusal is the tests below.
judged() {
    run python3 - "${H}/work" "$@" <<PY
import importlib.util, sys
sys.path.insert(0, "${GUARD_ROOT}/agent-hooks/claude-code")
spec = importlib.util.spec_from_file_location("area_guard", "${HOOK}")
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
for command in sys.argv[2:]:
    print(("held" if guard.credential_change(command, sys.argv[1]) else "passes") + "\t" + command)
PY
}

@test "credentials: every kind of change to a password, a key, a token or a login is held" {
    judged "${CHANGES[@]}"
    [ "${status}" -eq 0 ]
    [ "$(grep -c $'^held\t' <<< "${output}")" -eq "${#CHANGES[@]}" ] || { grep $'^passes\t' <<< "${output}"; return 1; }
}

@test "credentials: a command that only looks at a key, a token or a login passes" {
    judged "${LOOKS[@]}"
    [ "${status}" -eq 0 ]
    [ "$(grep -c $'^passes\t' <<< "${output}")" -eq "${#LOOKS[@]}" ] || { grep $'^held\t' <<< "${output}"; return 1; }
}

@test "credentials: a change is read past what runs it and inside what it hands on" {
    local wrapped=(
        "sudo passwd"
        "env FOO=1 gh auth login"
        "timeout 30 tailscale login"
        "bash -c 'gh auth login'"
        "echo ok && sh -c \"security delete-generic-password -s svc\""
        "eval 'ssh-keygen -t ed25519 -f k'"
        "x=\$(gh auth token) && echo \$(gh auth refresh)"
        "printf y | xargs -I{} npm token create"
        $'bash <<\'SH\'\ngh auth logout\nSH'
        "python3 -c 'import subprocess; subprocess.run([\"gh\", \"auth\", \"login\"])'"
    )
    for c in "${wrapped[@]}"; do
        bash_call "${c}"
        held || { echo "passed: ${c}"; echo "${output}"; return 1; }
    done
}

@test "credentials: a shell script the command runs is held to the same lines, its comments left out" {
    printf '#!/bin/sh\n# gh auth login is how you would sign in\necho hi\n' > "${H}/work/quiet.sh"
    bash_call "sh ${H}/work/quiet.sh"
    passed
    printf '#!/bin/sh\ngh auth login --web\n' > "${H}/work/login.sh"
    bash_call "bash ${H}/work/login.sh"
    held
}

@test "credentials: writing a file that keeps a key or a token is held, the other files there pass" {
    for f in "${H}/.ssh/id_ed25519" "${H}/.ssh/authorized_keys" "${H}/.config/gh/hosts.yml" \
             "${H}/.git-credentials" "${H}/agent-platform/secrets/bot/token"; do
        write_to "${f}"
        held || { echo "passed: ${f}"; return 1; }
    done
    bash_call "printf 'key' > ~/.ssh/id_rsa"
    held
    for f in "${H}/.ssh/config" "${H}/.ssh/known_hosts" "${H}/.config/gh/config.yml" "${H}/work/notes.md"; do
        write_to "${f}"
        passed || { echo "held: ${f}"; echo "${output}"; return 1; }
    done
}

@test "credentials: a change the agent showed passes on the operator's yes, once" {
    said "sign the gh CLI in again"
    bash_call "gh auth login --web"
    held
    [[ "${output}" == *'```guard'* ]]
    shown "gh auth login --web"
    said "はい"
    bash_call "gh auth login --web"
    passed
    bash_call "gh auth login --web" toolu_2
    held
}

@test "credentials: the judging names what the command changes" {
    run python3 -c "
import sys; sys.path.insert(0, '${GUARD_ROOT}/agent-hooks/claude-code')
import credentials
print(credentials.change(['gh', 'auth', 'login']))
print(credentials.change(['ssh-keygen', '-lf', 'k.pub']))"
    [ "${lines[0]}" = "gh auth login changes a login" ]
    [ "${lines[1]}" = "None" ]
}
