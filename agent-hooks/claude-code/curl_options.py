"""The words of a curl command read as curl reads its options: outgoing.py asks it before it reads
what each option sends.

A short option may be joined to its value (`-d@f`) or bundled with others (`-sSd @f`), and a long
option may take the next word as its value whatever that word looks like (`--data '-x'`). Each
option is put in a word of its own with its value as the next word, so the reader that follows
takes a value only after an option that has one. An option curl has and this does not know is
read as unknown, and so refused, rather than guessed.

The tables are from `curl --help all` (curl 8.7.1): an option whose help names an argument
(`<...>` or `[...]`) takes a value.
"""

from __future__ import annotations

#: Short options that take a value: the rest of the word, or the next word.
SHORT_VALUED = frozenset("EKCbcdDFPHhmoxUQreXYytzTuAw")
#: Short options that take none.
SHORT_FLAGS = frozenset("aqfGgI0ik46jlLMn:NZ#JORSs2318BvpV")
#: Long options that take a value: after `=`, or the next word.
LONG_VALUED = frozenset("""
abstract-unix-socket alt-svc aws-sigv4 cacert capath cert cert-type ciphers config connect-timeout
connect-to continue-at cookie cookie-jar create-file-mode crlfile curves data data-ascii data-binary
data-raw data-urlencode delegation dns-interface dns-ipv4-addr dns-ipv6-addr dns-servers doh-url
dump-header egd-file engine etag-compare etag-save expect100-timeout form form-string ftp-account
ftp-alternative-to-user ftp-method ftp-port ftp-ssl-ccc-mode happy-eyeballs-timeout-ms
haproxy-clientip header help hostpubmd5 hostpubsha256 hsts interface ipfs-gateway json keepalive-time
key key-type krb libcurl limit-rate local-port login-options mail-auth mail-from mail-rcpt
max-filesize max-redirs max-time netrc-file noproxy oauth2-bearer output output-dir parallel-max pass
pinnedpubkey preproxy proto proto-default proto-redir proxy proxy-cacert proxy-capath proxy-cert
proxy-cert-type proxy-ciphers proxy-crlfile proxy-header proxy-key proxy-key-type proxy-pass
proxy-pinnedpubkey proxy-service-name proxy-tls13-ciphers proxy-tlsauthtype proxy-tlspassword
proxy-tlsuser proxy-user proxy1.0 pubkey quote random-file range rate referer request request-target
resolve retry retry-delay retry-max-time sasl-authzid service-name socks4 socks4a socks5
socks5-gssapi-service socks5-hostname speed-limit speed-time stderr telnet-option tftp-blksize
time-cond tls-max tls13-ciphers tlsauthtype tlspassword tlsuser trace trace-ascii trace-config
unix-socket upload-file url url-query user user-agent variable write-out
""".split())
#: Long options that take none (`--no-<name>` turns one of them off).
LONG_FLAGS = frozenset("""
anyauth append basic ca-native cert-status compressed compressed-ssh create-dirs crlf digest disable
disable-eprt disable-epsv disallow-username-in-url doh-cert-status doh-insecure fail fail-early
fail-with-body false-start form-escape ftp-create-dirs ftp-pasv ftp-pret ftp-skip-pasv-ip ftp-ssl-ccc
ftp-ssl-control get globoff haproxy-protocol head http0.9 http1.0 http1.1 http2
http2-prior-knowledge http3 http3-only ignore-content-length include insecure ipv4 ipv6
junk-session-cookies list-only location location-trusted mail-rcpt-allowfails manual metalink
negotiate netrc netrc-optional next no-alpn no-buffer no-clobber no-keepalive no-npn
no-progress-meter no-sessionid ntlm ntlm-wb parallel parallel-immediate path-as-is post301 post302
post303 progress-bar proxy-anyauth proxy-basic proxy-ca-native proxy-digest proxy-http2
proxy-insecure proxy-negotiate proxy-ntlm proxy-ssl-allow-beast proxy-ssl-auto-client-cert
proxy-tlsv1 proxytunnel raw remote-header-name remote-name remote-name-all remote-time
remove-on-error retry-all-errors retry-connrefused sasl-ir show-error silent socks5-basic
socks5-gssapi socks5-gssapi-nec ssl ssl-allow-beast ssl-auto-client-cert ssl-no-revoke ssl-reqd
ssl-revoke-best-effort sslv2 sslv3 styled-output suppress-connect-headers tcp-fastopen tcp-nodelay
tftp-no-options tlsv1 tlsv1.0 tlsv1.1 tlsv1.2 tlsv1.3 tr-encoding trace-ids trace-time use-ascii
verbose version xattr
""".split())
#: Every option that takes a value, as it is written alone (`-d`, `--data`).
VALUED = frozenset({f"-{letter}" for letter in SHORT_VALUED} | {f"--{name}" for name in LONG_VALUED})


def curl_words(words: list[str]) -> tuple[list[str], str | None]:
    """The words of a curl command with each option a word of its own and its value the next one
    (`-sSd @f` -> `-s -S -d @f`, `--data -x` kept as it is); and why the words cannot be read, when
    an option is none this knows."""
    out, odd, at = words[:1], None, 1
    while at < len(words):
        word = words[at]
        at += 1
        if word == "--":
            out.extend(words[at - 1:])
            break
        if word.startswith("--"):
            name, has_value, _ = word.partition("=")
            out.append(word)
            long = name[2:]
            if long in LONG_VALUED:
                if not has_value and at < len(words):
                    out.append(words[at])
                    at += 1
            elif long not in LONG_FLAGS and not (long.startswith("no-") and long[3:] in LONG_FLAGS):
                odd = odd or f"a curl option it does not know ({name})"
            continue
        if not word.startswith("-") or word == "-":
            out.append(word)
            continue
        for place, letter in enumerate(word[1:], start=1):
            out.append(f"-{letter}")
            if letter in SHORT_VALUED:
                rest = word[place + 1:]
                if rest:
                    out.append(rest)
                elif at < len(words):
                    out.append(words[at])
                    at += 1
                break
            if letter not in SHORT_FLAGS:
                odd = odd or f"a curl option it does not know ({word})"
                break
    return out, odd
