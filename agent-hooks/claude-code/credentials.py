"""Which commands and files change how the operator signs in: a password, a PIN, a key, a token,
a login. area-guard.py holds such a call for the operator's yes, as it holds a change of the
guards. A command that only looks (a status, a list, printing a token or a public key) is not
one. Judging only: nothing here reads a file or runs a command."""

from __future__ import annotations

import fnmatch
import os
import re
from pathlib import Path

#: Programs that change a password or a login of the machine whatever their arguments.
ALWAYS = {
    "passwd", "chpass", "chpasswd", "smbpasswd", "vncpasswd", "kpasswd", "kinit", "kdestroy",
    "kswitch", "ssh-copy-id", "age-keygen",
}

#: Programs that hand the rest of their words on to another program to run.
RUNNERS = {"npx", "bunx", "uvx", "pnpx"}
#: Programs whose subcommand of these words hands the words after it on to another program.
RUNNER_SUBCOMMANDS = {
    "pnpm": {"dlx", "exec"}, "yarn": {"dlx", "exec"}, "npm": {"exec"}, "pipx": {"run"},
    "uv": {"run"}, "poetry": {"run"}, "bundle": {"exec"}, "mise": {"exec", "x"},
}

#: The command-line tools of services that sign in, keep tokens or keep keys. Their subcommands
#: are read by the shared lines below (login words, `auth <verb>`, a key noun and a change verb,
#: `config set <credential key>`).
SERVICE_TOOLS = {
    "gh", "glab", "npm", "pnpm", "yarn", "docker", "podman", "gcloud", "aws", "az", "firebase",
    "vercel", "wrangler", "cloudflared", "heroku", "fly", "flyctl", "netlify", "supabase", "hf",
    "huggingface-cli", "cargo", "gem", "poetry", "uv", "codex", "claude", "op", "bw", "lpass",
    "vault", "kubectl", "oc", "helm", "tailscale", "doctl", "terraform", "pulumi", "ngrok",
    "stripe", "railway", "eas", "expo", "sentry-cli", "modal", "wandb", "twine", "deno", "bun",
    "rclone", "gsutil", "linode-cli", "hcloud", "gemini", "ollama", "pass", "gopass", "step",
}

#: Subcommands that sign in or out, or make a token to sign in with.
LOGIN_WORDS = {
    "login", "logout", "signin", "signout", "sign-in", "sign-out", "adduser", "reauth",
    "setup-token", "add-authtoken", "authtoken",
}
#: The verbs after `auth` that only look.
AUTH_READS = {
    "status", "token", "list", "whoami", "show", "info", "help", "describe",
    "print-access-token", "print-identity-token",
}
#: Nouns of what signs in: a following change verb changes it (`gh secret set`, `npm token create`).
KEY_NOUNS = {
    "token", "tokens", "access-token", "access-tokens", "api-key", "api-keys", "apikey", "apikeys",
    "key", "keys", "ssh-key", "ssh-keys", "gpg-key", "gpg-keys", "deploy-key", "deploy-keys",
    "secret", "secrets", "credential", "credentials", "password", "passwords", "passphrase",
    "keypair", "key-pair", "pat", "authorizations", "item", "items", "vault", "account",
}
CHANGE_VERBS = {
    "create", "new", "add", "generate", "gen", "set", "put", "update", "edit", "rotate",
    "regenerate", "renew", "reset", "revoke", "delete", "remove", "rm", "destroy", "import",
    "upload", "change", "insert", "init", "mv", "cp", "move", "forget", "unlock", "change-pass",
}
#: Programs that keep passwords, where any change verb as the first subcommand changes one.
PASSWORD_STORES = {"pass", "gopass", "bw", "lpass"}
#: How many subcommand words of a service tool are read: options and their values come later.
SUBCOMMAND_WORDS = 4

#: A configuration key that holds a credential (`credential.helper`, `//registry/:_authToken`,
#: `pypi-token.pypi`, `http.extraHeader`).
CREDENTIAL_KEY = re.compile(
    r"(?:^|[._:/-])(?:token|_?authtoken|password|passwd|secret|credentials?|auth|api[-_]?key"
    r"|private[-_]?key|extraheader)(?:$|[._:/-])", re.IGNORECASE)
CONFIG_SET_VERBS = {"set", "add", "unset", "delete", "rm", "remove"}
CONFIG_WRITE_OPTIONS = {"--unset", "--unset-all", "--add", "--replace-all", "--remove-section"}
CONFIG_READ_OPTIONS = {"--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l"}

#: `security` subcommands that only look; `-s` on the keychain lists sets them instead.
SECURITY_READS = {
    "find-generic-password", "find-internet-password", "find-certificate", "find-identity",
    "find-key", "dump-keychain", "list-keychains", "default-keychain", "login-keychain",
    "show-keychain-info", "dump-trust-settings", "verify-cert", "cms", "smartcards", "error",
    "help", "leaks", "lock-keychain", "unlock-keychain", "export", "list-smartcards",
}
SECURITY_SETTERS = {"list-keychains", "default-keychain", "login-keychain"}
FDESETUP_READS = {
    "status", "list", "isactive", "haspersonalrecoverykey", "hasinstitutionalrecoverykey",
    "usingrecoverykey", "supportsauthrestart", "showdeferralinfo", "version", "help",
}
SYSADMINCTL_CHANGES = {
    "-resetpasswordfor", "-newpassword", "-securetokenon", "-securetokenoff", "-adduser",
    "-deleteuser", "-autologin",
}
DISKUTIL_CHANGES = {
    "changepassphrase", "setpassphrasehint", "encryptvolume", "decryptvolume",
    "changevolumepassphrase",
}
DSCL_EDITS = {"-create", "-change", "-append", "-delete", "-merge"}
DSCL_PASSWORD_ATTRIBUTE = re.compile(r"password|authenticationauthority|shadowhash", re.IGNORECASE)
#: The letters of `ssh-keygen` options that change a key or the hosts trusted.
SSH_KEYGEN_CHANGES = set("pRHcskA")
#: The letters of `ssh-keygen` options that only look at or convert a key.
SSH_KEYGEN_READS = set("lyFLBQYDrGTMei")
SSH_ADD_READS = set("lLT")
GPG_CHANGES = {
    "--gen-key", "--generate-key", "--full-gen-key", "--full-generate-key", "--quick-gen-key",
    "--quick-generate-key", "--quick-add-key", "--quick-add-uid", "--quick-revoke-uid",
    "--quick-revoke-sig", "--quick-set-expire", "--quick-set-primary-uid", "--passwd",
    "--change-passphrase", "--edit-key", "--delete-key", "--delete-keys", "--delete-secret-key",
    "--delete-secret-keys", "--delete-secret-and-public-key", "--delete-secret-and-public-keys",
    "--import", "--gen-revoke", "--generate-revocation", "--sign-key", "--lsign-key",
    "--quick-sign-key", "--quick-lsign-key", "--import-ownertrust", "--recv-key", "--recv-keys",
    "--fetch-keys", "--card-edit", "--edit-card", "--change-pin",
}
OPENSSL_KEY_MAKERS = {"genrsa", "genpkey", "gendsa"}
OPENSSL_KEY_TOOLS = {"rsa", "pkey", "ec", "dsa", "pkcs8", "pkcs12"}
#: A key tool's options that write the key under a new passphrase: `-passout` and a cipher.
OPENSSL_ENCRYPTS = re.compile(r"^-(?:passout|cipher|aes|des|camellia|seed|idea|bf|cast|sm4|chacha)")
GIT_GLOBAL_VALUED = {"-C", "-c", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
GIT_CREDENTIAL_CHANGES = {"approve", "reject", "store", "erase"}
TAILSCALE_REAUTH = re.compile(r"^--(?:auth-?key|force-reauth)(?:=|$)")
#: `gh api` endpoints of keys, tokens and secrets.
GH_API_CREDENTIALS = re.compile(
    r"(?:^|/)(?:keys|gpg_keys|ssh_signing_keys|deploy_keys|authorizations|access_tokens|secrets"
    r"|tokens|personal-access-tokens)(?:/|$)")
GH_API_BODY_OPTIONS = {"-f", "-F", "--field", "--raw-field", "--input"}
BIOUTIL_CHANGES = {"-w", "-p", "-d", "--write-config", "--purge", "--delete"}
LOGIN_WINDOW = re.compile(r"loginwindow|askforpassword", re.IGNORECASE)


def change(words: list[str]) -> str | None:
    """What a simple command changes of how the operator signs in, or None. `words` start at the
    program, past what runs it (`sudo`, `env`, `xargs`: area-guard.py's program_words)."""
    words = _past_runners(words)
    if not words:
        return None
    program = os.path.basename(words[0]).lower()
    args = words[1:]
    judge = SPECIFIC.get(program)
    if judge is not None:
        if found := judge(args):
            return f"{program} {found}"
        return None
    if program in ALWAYS:
        return f"{program} changes a password or a login"
    if program.startswith("git-credential-"):
        verb = _positional(args)[:1]
        return f"{program} {verb[0]}" if set(verb) & GIT_CREDENTIAL_CHANGES else None
    if program in SERVICE_TOOLS:
        return _service_change(program, args)
    return None


def _past_runners(words: list[str]) -> list[str]:
    """The words from the program a package runner runs (`npx vercel login` -> `vercel login`)."""
    for _ in range(4):
        if not words:
            return words
        program = os.path.basename(words[0]).lower()
        rest = words[1:]
        if program in RUNNERS:
            words = _from_first_positional(rest)
        elif rest and _positional(rest)[:1] and _positional(rest)[0] in RUNNER_SUBCOMMANDS.get(program, ()):
            words = _from_first_positional(rest[rest.index(_positional(rest)[0]) + 1:])
        else:
            return words
    return words


def _from_first_positional(words: list[str]) -> list[str]:
    at = next((i for i, w in enumerate(words) if not w.startswith("-")), len(words))
    return words[at:]


def _positional(args: list[str]) -> list[str]:
    return [a for a in args if not a.startswith("-")]


def _letters(args: list[str]) -> set[str]:
    """The letters of the short options among `args` (`-lf` gives l and f)."""
    return {c for a in args if a.startswith("-") and not a.startswith("--") for c in a[1:]}


def _service_change(program: str, args: list[str]) -> str | None:
    words = _positional(args)[:SUBCOMMAND_WORDS]
    pieces = [piece for w in words for piece in w.split(":")]
    if program in PASSWORD_STORES and pieces[:1] and pieces[0] in CHANGE_VERBS | LOGIN_WORDS:
        return f"{program} {pieces[0]} changes a stored password"
    for i, word in enumerate(pieces):
        if word in LOGIN_WORDS:
            return f"{program} {' '.join(pieces[:i + 1])} signs in or out"
        if word == "auth" and i + 1 < len(pieces) and pieces[i + 1] not in AUTH_READS:
            return f"{program} {' '.join(pieces[:i + 2])} changes a login"
        if word in KEY_NOUNS and i + 1 < len(pieces) and pieces[i + 1] in CHANGE_VERBS:
            return f"{program} {' '.join(pieces[:i + 2])} changes a key, a token or a secret"
        if word in CHANGE_VERBS and i + 1 < len(pieces) and pieces[i + 1] in {"secret", "secrets"}:
            return f"{program} {' '.join(pieces[:i + 2])} changes a secret"
    if key := _config_key(words, args):
        return f"{program} config {key} sets a credential"
    if program == "gh" and pieces[:1] == ["api"]:
        return _gh_api(args)
    if program == "tailscale":
        return _tailscale(pieces, args)
    if program == "kubectl" and pieces[:2] == ["config", "set-credentials"]:
        return "kubectl config set-credentials changes a login"
    if program == "aws":
        return _aws(pieces)
    return None


def _config_key(words: list[str], args: list[str]) -> str | None:
    """The credential key a `config` subcommand writes (`npm config set //r/:_authToken x`,
    `poetry config pypi-token.pypi x`, `git config --unset credential.helper`), or None."""
    if "config" not in words:
        return None
    rest = words[words.index("config") + 1:]
    options = {a.split("=", 1)[0] for a in args if a.startswith("-")}
    if options & CONFIG_READ_OPTIONS and not options & CONFIG_WRITE_OPTIONS:
        return None
    if rest[:1] and rest[0] in CONFIG_SET_VERBS:
        key = rest[1] if len(rest) > 1 else None
    elif options & CONFIG_WRITE_OPTIONS or len(rest) >= 2:
        key = rest[0] if rest else None
    else:
        key = None
    return key if key and CREDENTIAL_KEY.search(key) else None


def _gh_api(args: list[str]) -> str | None:
    endpoint = next((a for a in _positional(args)[1:]), "")
    if not GH_API_CREDENTIALS.search(endpoint):
        return None
    method = next((args[i + 1] for i, a in enumerate(args[:-1]) if a in {"-X", "--method"}), None)
    method = method or next((a.split("=", 1)[1] for a in args if a.startswith("--method=")), None)
    writes = method.upper() != "GET" if method else bool(set(args) & GH_API_BODY_OPTIONS)
    return f"api {endpoint} writes a key, a token or a secret" if writes else None


def _tailscale(pieces: list[str], args: list[str]) -> str | None:
    if pieces[:1] == ["switch"]:
        return "tailscale switch changes the login"
    if pieces[:1] == ["up"] and any(TAILSCALE_REAUTH.match(a) for a in args):
        return "tailscale up signs in again"
    if pieces[:1] == ["lock"] and pieces[1:2] not in (["status"], ["log"], []):
        return f"tailscale lock {pieces[1]} changes the tailnet's signing keys"
    if pieces[:1] == ["cert"]:
        return "tailscale cert makes a TLS key"
    return None


def _aws(pieces: list[str]) -> str | None:
    if pieces[:1] == ["configure"] and pieces[1:2] not in (["get"], ["list"], ["list-profiles"],
                                                           ["export-credentials"]):
        return "aws configure sets the keys"
    action = pieces[1] if len(pieces) > 1 else ""
    if re.match(r"(?:create|delete|update|put|rotate|reset|change|upload|enable|deactivate|resync)-", action) \
            and re.search(r"secret|access-key|login-profile|password|credential|ssh-public-key|mfa"
                          r"|signing-certificate|key-pair|api-key", action):
        return f"aws {pieces[0]} {action} changes a key or a secret"
    return None


def _security(args: list[str]) -> str | None:
    verb = _positional(args)[:1]
    if not verb:
        return None
    if verb[0] in SECURITY_SETTERS and "-s" in args:
        return f"{verb[0]} -s sets the keychains"
    if verb[0] == "authorizationdb":
        rest = _positional(args)[1:2]
        return None if rest == ["read"] else "authorizationdb changes who may sign in to what"
    return None if verb[0] in SECURITY_READS else f"{verb[0]} changes the keychain"


def _fdesetup(args: list[str]) -> str | None:
    verb = _positional(args)[:1]
    return f"{verb[0]} changes FileVault's keys" if verb and verb[0].lower() not in FDESETUP_READS else None


def _sysadminctl(args: list[str]) -> str | None:
    found = [a for a in args if a.lower() in SYSADMINCTL_CHANGES]
    return f"{found[0]} changes a password or a login" if found else None


def _diskutil(args: list[str]) -> str | None:
    found = [a for a in args if a.lower() in DISKUTIL_CHANGES]
    return f"{found[0]} changes a disk's passphrase" if found else None


def _dscl(args: list[str]) -> str | None:
    if "-passwd" in args:
        return "-passwd changes a password"
    if set(args) & DSCL_EDITS and any(DSCL_PASSWORD_ATTRIBUTE.search(a) for a in args):
        return "changes a password attribute"
    return None


def _pwpolicy(args: list[str]) -> str | None:
    found = [a for a in args if re.match(r"-(?:set|clear|enable|disable)", a, re.IGNORECASE)]
    return f"{found[0]} changes the password policy" if found else None


def _ssh_keygen(args: list[str]) -> str | None:
    letters = _letters(args)
    if letters & SSH_KEYGEN_CHANGES:
        return f"-{sorted(letters & SSH_KEYGEN_CHANGES)[0]} changes a key or the trusted hosts"
    if letters & SSH_KEYGEN_READS:
        return None
    return "makes a key"


def _ssh_add(args: list[str]) -> str | None:
    return None if _letters(args) & SSH_ADD_READS else "changes the keys the agent signs in with"


def _gpg(args: list[str]) -> str | None:
    found = [a for a in args if a.split("=", 1)[0] in GPG_CHANGES]
    return f"{found[0]} changes a key" if found else None


def _git(args: list[str]) -> str | None:
    rest, skip = [], False
    for i, a in enumerate(args):
        if skip:
            skip = False
        elif a in GIT_GLOBAL_VALUED:
            skip = True
        elif a.startswith("-") and not rest:
            continue
        else:
            rest = args[i:]
            break
    if rest[:1] and (rest[0] == "credential" or rest[0].startswith("credential-")) \
            and set(_positional(rest[1:])[:1]) & GIT_CREDENTIAL_CHANGES:
        return f"{rest[0]} {_positional(rest[1:])[0]} changes a stored login"
    if rest[:1] == ["config"] and (key := _config_key(["config", *_positional(rest[1:])], rest[1:])):
        return f"config {key} sets a credential"
    return None


def _openssl(args: list[str]) -> str | None:
    verb = _positional(args)[:1]
    if not verb:
        return None
    if verb[0] in OPENSSL_KEY_MAKERS:
        return f"{verb[0]} makes a key"
    if verb[0] == "req" and "-newkey" in args:
        return "req -newkey makes a key"
    if verb[0] == "ecparam" and "-genkey" in args:
        return "ecparam -genkey makes a key"
    if verb[0] in OPENSSL_KEY_TOOLS and any(OPENSSL_ENCRYPTS.match(a) for a in args):
        return f"{verb[0]} sets a key's passphrase"
    if verb[0] in OPENSSL_KEY_TOOLS and any(a.startswith("-passin") for a in args) and "-out" in args:
        return f"{verb[0]} writes a key without its passphrase"
    return None


def _htpasswd(args: list[str]) -> str | None:
    return None if "-v" in args else "changes a password"


def _key_maker(letters: str):
    def judge(args: list[str]) -> str | None:
        found = _letters(args) & set(letters)
        return f"-{sorted(found)[0]} makes or changes a key" if found else None
    return judge


def _wg(args: list[str]) -> str | None:
    verb = _positional(args)[:1]
    if verb and verb[0] in {"genkey", "genpsk"}:
        return f"{verb[0]} makes a key"
    if verb == ["set"] and {"private-key", "preshared-key"} & set(args):
        return "set changes a key"
    return None


def _bioutil(args: list[str]) -> str | None:
    found = [a for a in args if a in BIOUTIL_CHANGES]
    return f"{found[0]} changes Touch ID" if found else None


def _defaults(args: list[str]) -> str | None:
    verb = _positional(args)[:1]
    if verb and verb[0] in {"write", "delete"} and any(LOGIN_WINDOW.search(a) for a in args):
        return f"{verb[0]} changes how the Mac signs in"
    return None


def _op(args: list[str]) -> str | None:
    words = _positional(args)[:SUBCOMMAND_WORDS]
    if words[:1] and words[0] in LOGIN_WORDS:
        return f"{words[0]} signs in or out"
    if len(words) > 1 and words[1] in CHANGE_VERBS:
        return f"{words[0]} {words[1]} changes a stored password"
    return None


#: The programs judged by their own reading of the arguments.
SPECIFIC = {
    "security": _security, "fdesetup": _fdesetup, "sysadminctl": _sysadminctl,
    "diskutil": _diskutil, "dscl": _dscl, "pwpolicy": _pwpolicy, "ssh-keygen": _ssh_keygen,
    "ssh-add": _ssh_add, "gpg": _gpg, "gpg2": _gpg, "git": _git, "openssl": _openssl,
    "htpasswd": _htpasswd, "minisign": _key_maker("GC"), "signify": _key_maker("G"), "wg": _wg,
    "bioutil": _bioutil, "defaults": _defaults, "op": _op,
}

#: Files that hold a password, a key or a token, from the home folder.
HOME_FILES = (
    ".ssh/id_*", ".ssh/*.pem", ".ssh/*.key", ".ssh/authorized_keys*", ".ssh/identity*",
    ".ssh/allowed_signers", ".gnupg/**", "Library/Keychains/**", ".config/gh/hosts.yml",
    ".netrc", ".git-credentials", ".config/git/credentials", ".docker/config.json", ".npmrc",
    ".aws/credentials", ".config/gcloud/**", ".azure/**", ".config/op/**", ".password-store/**",
    ".pypirc", ".cargo/credentials", ".cargo/credentials.toml", ".gem/credentials",
    ".cache/huggingface/token", ".huggingface/token", ".claude/.credentials.json",
    "agent-platform/secrets/**",
)
#: Files outside the home folder that hold the machine's sign-in.
MACHINE_FILES = ("/etc/kcpassword",)


def credential_file(path: Path, home: Path) -> bool:
    """Whether writing `path` (already resolved) changes a password, a key or a token kept in a
    file. `home` is the resolved home folder."""
    if path.as_posix() in MACHINE_FILES:
        return True
    try:
        relative = path.relative_to(home).as_posix()
    except ValueError:
        return False
    return any(_matches(relative, pattern) for pattern in HOME_FILES)


def _matches(relative: str, pattern: str) -> bool:
    """`folder/**` is everything under the folder; another pattern matches one file at its depth."""
    if pattern.endswith("/**"):
        folder = pattern[:-3]
        return relative == folder or relative.startswith(folder + "/")
    return fnmatch.fnmatchcase(relative, pattern) and relative.count("/") == pattern.count("/")
