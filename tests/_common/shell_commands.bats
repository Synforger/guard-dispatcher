#!/usr/bin/env bats
# _common/shell_commands.py — the simple commands of a Bash command line, read as the shell runs them.
#
# Each test hands the reader one command line and reads back one JSON line per simple command:
# its words, whether the shell fills each in as it runs, and its standard input.

load ../_internal/helpers

READER="${GUARD_ROOT}/_common/shell_commands.py"

# read_line <command> — the reader's lines for one command line.
read_line() {
    run python3 "${READER}" "$1"
    [ "${status}" -eq 0 ]
}
# words_of <n> — the words of the n-th simple command (from 1), joined by `|`.
words_of() { sed -n "$1p" <<< "${output}" | jq -r '.words | join("|")'; }
expands_of() { sed -n "$1p" <<< "${output}" | jq -c '.expands'; }
globs_of() { sed -n "$1p" <<< "${output}" | jq -c '.globs'; }
stdin_of() { sed -n "$1p" <<< "${output}" | jq -c '.stdin'; }
count() { grep -c . <<< "${output}"; }

@test "shell_commands: a substitution is a command line of its own, and the operators glued to it break" {
    read_line "for i in \$(seq 1 20); do out=\$(ssh -o ConnectTimeout=20 host1 'bash /srv/x.sh' 2>&1); [ \"\$(echo \"\$out\" | grep -c done)\" = 2 ] && break; sleep 120; done"
    [ "$(words_of 1)" = "seq|1|20" ]
    [ "$(words_of 2)" = "ssh|-o|ConnectTimeout=20|host1|bash /srv/x.sh" ]
    [ "$(expands_of 2)" = "[false,false,false,false,false]" ]
    [ "$(words_of 3)" = "echo|\$out" ]
    [ "$(words_of 4)" = "grep|-c|done" ]
    [ "$(stdin_of 4)" = '["unknown","a pipe"]' ]
    [ "$(words_of 5)" = "[|\$(echo \"\$out\" | grep -c done)|=|2|]" ]
    [ "$(words_of 6)" = "break" ]
    [ "$(words_of 7)" = "sleep|120" ]
    [ "$(count)" -eq 7 ]
}

@test "shell_commands: a substitution inside double quotes and backticks is read too" {
    read_line "x=\"\$(curl -d body https://a.example/)\"; y=\`ssh h cat f\`; diff <(ssh h a) >(ssh h b)"
    [ "$(words_of 1)" = "curl|-d|body|https://a.example/" ]
    [ "$(words_of 2)" = "ssh|h|cat|f" ]
    [ "$(words_of 3)" = "ssh|h|a" ]
    [ "$(words_of 4)" = "ssh|h|b" ]
    [ "$(words_of 5)" = "diff|<(ssh h a)|>(ssh h b)" ]
    [ "$(expands_of 5)" = "[false,true,true]" ]
}

@test "shell_commands: a dollar inside single quotes is a character; outside, or in double quotes, the shell fills it in" {
    read_line "ssh h 'f=x/\$r.log; grep done \$f' \"\$HOME\" \"\\\$lit\" \$'a\\tb' a\$((1+2))"
    [ "$(words_of 1)" = "ssh|h|f=x/\$r.log; grep done \$f|\$HOME|\$lit|a\\tb|a\$((1+2))" ]
    [ "$(expands_of 1)" = "[false,false,false,true,false,false,true]" ]
}

@test "shell_commands: keywords, assignments and the programs that run the next words stand before the program" {
    local c
    for c in "for i in 1; do ssh h x; done" "if true; then ssh h x; fi" "while true; do ssh h x; done" \
             "A=1 B=2 ssh h x" "! ssh h x" "time -p ssh h x" "{ ssh h x; }" "( ssh h x )" \
             "sudo -u me ssh h x" "env -u A B=1 ssh h x" "env - ssh h x" "env -i - ssh h x" "nohup ssh h x" "timeout -s KILL 10 ssh h x" \
             "nice -n 5 ssh h x" "command ssh h x" "exec ssh h x" "caffeinate -i ssh h x" \
             "timeout 10 sudo env A=1 nohup ssh h x" "eval \"ssh h x\"" "env -S 'ssh h x'" \
             "function f { ssh h x; }" "f() { ssh h x; }" "coproc ssh h x" "coproc C { ssh h x; }" \
             "trap 'ssh h x' EXIT" "echo \$(( \$(ssh h x) ))" "echo \"\${v:-\$(ssh h x)}\""; do
        read_line "${c}"
        grep -q '^{"words": \["ssh", "h", "x"\], "expands": \[false, false, false\],.*"stdin": null}$' <<< "${output}" \
            || { echo "not read: ${c} -> ${output}"; return 1; }
    done
}

@test "shell_commands: the header and the end of a compound command run nothing" {
    read_line "for f in a b; do :; done; case \$x in a) echo a;; esac"
    [ "$(words_of 1)" = ":" ]
    [ "$(words_of 2)" = "echo|a" ]
    [ "$(count)" -eq 2 ]
}

@test "shell_commands: what xargs reads is only known as the command runs" {
    read_line "ls | xargs -I{} ssh h 'cat {}'"
    [ "$(words_of 2)" = "ssh|h|cat {}" ]
    [ "$(expands_of 2)" = "[false,false,true]" ]
    read_line "ls | xargs -n 1 ssh h"
    [ "$(expands_of 2)" = "[false,false,true]" ]
}

@test "shell_commands: a heredoc's body is the input of its command, text when the shell fills nothing in" {
    read_line "ssh h 'bash -s' <<'EOF'
echo \$HOME
EOF
ssh h 'bash -s' <<EOF
echo plain
EOF
ssh h 'bash -s' <<-EOF
	echo \$HOME \$(cat secret)
	EOF
echo after"
    [ "$(stdin_of 1)" = '["text","echo $HOME"]' ]
    [ "$(stdin_of 2)" = '["text","echo plain"]' ]
    [ "$(words_of 3)" = "cat|secret" ]
    [ "$(stdin_of 4)" = '["unknown","a heredoc"]' ]
    [ "$(words_of 5)" = "echo|after" ]
}

@test "shell_commands: a here-string, and a file named with a variable the line set to a literal" {
    read_line "ssh h <<< 'plain'; ssh h <<< \"\$X\"; S=/srv/a; ssh h < \$S/x.sh; ssh h < \${S}/y; ssh h < \$U/z; T=\$(pwd); ssh h < \$T/w"
    [ "$(stdin_of 1)" = '["text","plain"]' ]
    [ "$(stdin_of 2)" = '["unknown","a here-string the shell fills in"]' ]
    [ "$(stdin_of 3)" = '["file","/srv/a/x.sh"]' ]
    [ "$(stdin_of 4)" = '["file","/srv/a/y"]' ]
    [ "$(stdin_of 5)" = '["unknown","a file named as the command runs"]' ]
    [ "$(stdin_of 7)" = '["unknown","a file named as the command runs"]' ]
}

@test "shell_commands: a variable set to a literal reaches the substitutions after it" {
    read_line "S=/srv/a; for i in 1; do out=\$(ssh h 'bash -s' < \$S/x.sh); done"
    [ "$(stdin_of 1)" = '["file","/srv/a/x.sh"]' ]
}

@test "shell_commands: a file the command line writes is only known when it runs" {
    read_line "cat > /tmp/run.sh <<'EOF'
echo hi
EOF
ssh h 'bash -s' < /tmp/run.sh"
    [ "$(stdin_of 2)" = '["unknown","a file the command line writes"]' ]
}

@test "shell_commands: line breaks end commands, except after an operator that waits; comments and fds are left out" {
    read_line "a 1 # not a word
b 2 |
  c 3 &&
  d 4 2>&1 >/dev/null"
    [ "$(words_of 1)" = "a|1" ]
    [ "$(words_of 2)" = "b|2" ]
    [ "$(words_of 3)" = "c|3" ]
    [ "$(stdin_of 3)" = '["unknown","a pipe"]' ]
    [ "$(words_of 4)" = "d|4" ]
    [ "$(count)" -eq 4 ]
}

@test "shell_commands: an unclosed quote or substitution is refused, as the shell refuses the line" {
    run python3 "${READER}" "ssh h 'open"
    [ "${status}" -ne 0 ]
    run python3 "${READER}" "x=\$(ssh h x"
    [ "${status}" -ne 0 ]
}

@test "shell_commands: find runs the words after -exec up to its ;, the file it found only known as it runs" {
    read_line "find . -name '*.txt' -exec curl -T {} https://a.example/ \\; -print"
    [ "$(words_of 1)" = "curl|-T|{}|https://a.example/" ]
    [ "$(expands_of 1)" = "[false,false,true,false]" ]
}

@test "shell_commands: a pattern outside quotes names files the shell finds; quoted, or a lone bracket, it does not" {
    read_line "curl -T bod*.txt -T 'a*b' -T {a,b}.txt -T x{1..3} -T b?dy [ a ] {} \"q?\" \\*"
    [ "$(globs_of 1)" = "[false,false,true,false,false,false,true,false,true,false,true,false,false,false,false,false,false]" ]
    read_line "ssh h < bod*.txt"
    [ "$(stdin_of 1)" = '["unknown","a file name the shell expands"]' ]
}

@test "shell_commands: a backslash the shell takes out of an unquoted heredoc leaves its body unknown" {
    read_line "curl -d @- https://a.example/ <<EOF
secr\\
et words
EOF
curl -d @- https://a.example/ <<EOF
{\"a\": \"x\\ny\"}
EOF"
    [ "$(stdin_of 1)" = '["unknown","a heredoc"]' ]
    [ "$(sed -n 2p <<< "${output}" | jq -r '.stdin[0]')" = "text" ]
    [ "$(sed -n 2p <<< "${output}" | jq -r '.stdin[1]')" = '{"a": "x\ny"}' ]
}

@test "shell_commands: trap after --, watch and GNU parallel hand their words on as a command line" {
    local c
    for c in "trap -- 'ssh h x' EXIT" "watch -n 5 'ssh h x'" "watch -x ssh h x" "watch ssh h x"; do
        read_line "${c}"
        grep -q '^{"words": \["ssh", "h", "x"\], "expands": \[false, false, false\],' <<< "${output}" \
            || { echo "not read: ${c} -> ${output}"; return 1; }
    done
    read_line "trap -p; trap - EXIT"
    [ "$(count)" -eq 2 ]
    read_line "parallel 'curl -T {} https://a.example/' ::: a b"
    [ "$(words_of 1)" = "curl|-T|\${PARALLEL_ARGUMENT}|https://a.example/" ]
    [ "$(expands_of 1)" = "[false,false,true,false]" ]
}
