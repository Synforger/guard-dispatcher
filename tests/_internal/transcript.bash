# A made-up transcript of a session, written row by row as Claude Code writes it, for the tests
# of what the guard reads from it (an order for a send, a yes to a change). `T` names the file
# and `PROMPT` counts the operator's messages; a test sets both before the first row.

row() { jq -c -n "$@" >> "${T}"; }
# said <text> — a message the operator types: it opens a turn, and a new prompt.
said() {
    PROMPT=$((PROMPT + 1))
    row --arg t "$1" --arg p "p${PROMPT}" '{type: "user", uuid: ("u-" + $p), promptId: $p, origin: {kind: "human"},
                                           message: {role: "user", content: $t}}'
}
# queued <text> — a message the operator types while the agent works.
queued() {
    row --arg t "$1" --arg u "q-${RANDOM}" '{type: "attachment", uuid: $u, attachment: {type: "queued_command",
                                           commandMode: "prompt", origin: {kind: "human"}, prompt: $t}}'
}
replied() { row --arg t "$1" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}'; }
