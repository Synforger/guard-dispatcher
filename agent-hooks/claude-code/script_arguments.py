"""Which words handed to a file of code may name a file the code writes: the judgement of a script that
writes where its arguments say (area-guard.py's script_argument_orders). Pure: it reads no file.

The guard reads a script as the code written into the command, and a word handed to it is no path
that code names. A script given what the agent may not write (the guard's settings, a session's
transcript, the folder of transcripts) is read again with its arguments in place: a shell script's
`$1`..`$9`, `$@`, `$*`, `${1:-x}`, a loop over them and a `shift` (`shell_variants`), a Python file's
`sys.argv` (code_writes.python). The code of an interpreter the guard has no reading of
(`writes_where_told`) writes the words when it uses its arguments and spells a call that writes.
"""

from __future__ import annotations

import re
import shlex

#: A positional parameter of a shell script: `$1` `${1}` `${1:-x}` `${1=x}` `$@` `${@}` `$*` `${@:2}`.
POSITIONAL = re.compile(
    r"\$(?:(?P<digit>[1-9])|\{(?P<braced>[1-9])(?::?(?P<operator>[-=])(?P<default>[^}]*))?\}"
    r"|(?P<all>[@*])|\{(?P<every>[@*])(?::(?P<from>\d+))?\})")
#: `"$@"`: each word is a word of its own, whatever it holds.
QUOTED_EACH = re.compile(r'"\$(?:@|\{@\})"')
#: A word that needs no quoting wherever it stands in a command line.
PLAIN_WORD = re.compile(r"[\w@%+=:,./~-]+")
#: `shift` or `shift 2` standing alone on a line.
SHIFT_LINE = re.compile(r"\s*shift(?:\s+(\d+))?\s*;?\s*")
#: `for f in <list>; do` and `for f; do` (a loop over the arguments themselves).
FOR_LOOP = re.compile(r"\bfor\s+(?P<variable>\w+)(?:\s+in\s+(?P<list>[^;\n]*?))?\s*(?:;|\n)\s*do\b")
#: What takes a shell script's words where they cannot be read from the text.
UNREADABLE = re.compile(r"\bgetopts?\b|\bset\s+--|\$\{!|\beval\b")
#: Words that open and close a block of shell: a `shift` inside one runs a number of times the text does not say.
BLOCK_OPENS = re.compile(r"\b(?:do|then|case)\b|\{|\(\)")
BLOCK_CLOSES = re.compile(r"\b(?:done|fi|esac)\b|\}")

#: Per interpreter the guard has no reading of: how its code takes its arguments, and the spellings of a
#: call that writes a file or runs a program (which may write any).
_USES_ARGUMENTS = {
    "node": re.compile(r"process\.argv|Deno\.args|Bun\.argv"),
    "ruby": re.compile(r"\bARGV\b|\bARGF\b"),
    "perl": re.compile(r"@ARGV|\$ARGV|\bARGV\b|\bshift\b|<>"),
    "php": re.compile(r"\$argv|\$_SERVER\s*\[\s*['\"]argv"),
    "osascript": re.compile(r"\bon\s+run\b|\bargv\b"),
}
_WRITES = {
    "node": re.compile(r"\b(?:writeFile|appendFile|createWriteStream|rm|rmdir|unlink|rename|copyFile|cp|truncate|"
                       r"mkdir|symlink|link|chmod|open|exec|execFile|spawn|fork|write)(?:Sync)?\b|child_process"),
    "ruby": re.compile(r"File\.(?:write|binwrite|open|new|delete|unlink|rename|truncate|chmod|symlink)|FileUtils|"
                       r"IO\.(?:write|binwrite|popen)|\.write\b|\bsystem\b|\bexec\b|`|%x|Open3|Dir\.(?:rmdir|mkdir)"),
    "perl": re.compile(r"\bopen\b[^;]*['\"]\s*\+?[>|]|\b(?:unlink|rename|rmdir|mkdir|system|exec|syswrite|chmod|"
                       r"symlink|truncate)\b|`|File::(?:Copy|Path|Slurp)|\bcopy\b|\bmove\b"),
    "php": re.compile(r"\b(?:file_put_contents|fopen|fwrite|unlink|rename|copy|rmdir|mkdir|chmod|symlink|exec|"
                      r"system|shell_exec|passthru|proc_open|popen)\b"),
    "osascript": re.compile(r"\bdo\s+shell\s+script\b|\bwrite\b|\bdelete\b|\bmove\b|\bduplicate\b|\bmake\b"),
}


def shell_variants(code: str, words: list[str]) -> tuple[list[str], bool]:
    """(the script written out with the words in place, once for each word a loop over the arguments
    takes, whether the script uses its arguments in a way the text does not say).

    `$1`..`$9` are the n-th word (empty when there is none; `${1:-x}` is `x` then), `$@` and `$*` all of
    them, `${@:n}` those from the n-th. A `shift` on a line of its own at the top of the script moves the
    words on from there. A `shift` inside a block, `getopts`, `set --`, `${!n}` and `eval` take the
    words where the text does not say: the second value is True."""
    filled, shifted_in_a_block = _without_shifts(code, words)
    texts = [filled]
    unreadable = shifted_in_a_block or bool(UNREADABLE.search(code))
    for loop in FOR_LOOP.finditer(filled):
        listed = loop.group("list")
        if listed is not None and not _loops_over_words(listed, words):
            continue
        try:
            items = shlex.split(listed) if listed is not None else list(words)
        except ValueError:
            return texts, True
        variable = re.escape(loop.group("variable"))
        for item in items:
            texts.append(re.sub(rf"\$\{{{variable}\}}|\${variable}\b", lambda _: _spelled(item), filled))
    return texts, unreadable


def uses_arguments(program: str, code: str) -> bool:
    """Whether code of an interpreter the guard has no reading of takes its arguments."""
    pattern = _USES_ARGUMENTS.get(program)
    return pattern is not None and bool(pattern.search(code))


def writes_where_told(program: str, code: str) -> bool:
    """Whether code of an interpreter the guard has no reading of takes its arguments and spells a
    call that writes a file or runs a program: then it may write any word it is handed."""
    pattern = _WRITES.get(program)
    return uses_arguments(program, code) and pattern is not None and bool(pattern.search(code))


def candidates(words: list[str]) -> list[str]:
    """What each word may name: the word, and what follows an `=` in it (`--out=<path>`)."""
    return [part for word in words for part in (word, word.partition("=")[2]) if part]


def _spelled(word: str) -> str:
    return word if PLAIN_WORD.fullmatch(word) else shlex.quote(word)


def _filled(text: str, words: list[str]) -> str:
    """The text with each positional parameter written out from `words`."""
    def fill(match: re.Match[str]) -> str:
        number = match["digit"] or match["braced"]
        if number:
            given = words[int(number) - 1] if int(number) <= len(words) else ""
            if match["operator"] and not given:
                return match["default"]
            return _spelled(given) if given else ""
        start = int(match["from"] or 1) - 1 if match["every"] else 0
        return " ".join(_spelled(word) for word in words[start:])

    return POSITIONAL.sub(fill, QUOTED_EACH.sub(lambda _: " ".join(_spelled(word) for word in words), text))


def _without_shifts(code: str, words: list[str]) -> tuple[str, bool]:
    """(the script with each `shift` at its top level applied to what follows it, and whether one sits
    inside a block). The words of each stretch are written out here; the rest of the text is not touched."""
    depth, left, out, inside = 0, list(words), [], False
    for line in code.splitlines():
        shift = SHIFT_LINE.fullmatch(line)
        if shift and depth == 0:
            left = left[int(shift.group(1) or 1):]
            continue
        inside = inside or bool(re.search(r"\bshift\b", line))
        out.append(_filled(line, left))
        depth += len(BLOCK_OPENS.findall(line)) - len(BLOCK_CLOSES.findall(line))
        depth = max(depth, 0)
    return "\n".join(out), inside


def _loops_over_words(listed: str, words: list[str]) -> bool:
    """Whether the list a loop runs over (with the words already written in) holds one of them."""
    try:
        return any(item in words for item in shlex.split(listed))
    except ValueError:
        return True
