"""The parts of Python code that can name a file the code writes: area-guard.py's named() finds the
paths in what this returns (code_paths) instead of in the whole code.

The code is read as a syntax tree. What a call writes is its target: the file of an `open` in a
writing mode, the receiver of a method that writes the file it names (`Path.write_text`), and
every argument of a call this module does not know (`shutil.copy`, `subprocess.run`, a library's
`save`), since such a call may write whatever it is given. A call known to only read or to turn
values into other values (`os.path.relpath`, a string's methods, `Path.read_text`, `print`) has no
target: a path handed to it is text. A name is followed back to every value assigned to it (and a
local function's parameters to the arguments of its calls), so `p = Path("a"); p.write_text(x)`
gives the source of `p` and of `Path("a")`. Code that does not parse gives itself whole.
"""

from __future__ import annotations

import ast
import re

#: Modules whose functions write no file they are handed a path for (they read, or compute).
PURE_MODULES = ("os.path", "posixpath", "re", "fnmatch", "glob", "json", "shlex", "urllib.parse", "html",
                "textwrap", "string", "math", "datetime", "time", "hashlib", "base64", "collections",
                "itertools", "functools", "difflib", "unicodedata", "operator", "statistics", "decimal",
                "fractions", "uuid", "typing", "dataclasses", "enum", "copy", "pprint", "csv", "sys")
#: Functions that write no file they are handed a path for.
PURE_FUNCTIONS = frozenset({
    "print", "len", "str", "repr", "format", "int", "float", "bool", "list", "tuple", "dict", "set",
    "frozenset", "sorted", "reversed", "enumerate", "zip", "min", "max", "sum", "any", "all", "isinstance",
    "issubclass", "abs", "round", "range", "chr", "ord", "hex", "oct", "bin", "id", "hash", "type", "iter",
    "next", "divmod", "pow", "callable", "bytes", "bytearray",
    "pathlib.Path", "pathlib.PurePath", "pathlib.PosixPath", "pathlib.PurePosixPath",
    "os.getcwd", "os.listdir", "os.scandir", "os.walk", "os.stat", "os.lstat", "os.getenv", "os.fspath",
    "os.fsdecode", "os.fsencode", "os.environ.get", "os.access", "os.cpu_count", "os.getpid",
})
#: Methods that write no file: a string's, a mapping's or a sequence's, a path's that read, a match's,
#: an open file's (what it writes was opened for writing, which the `open` already gives).
PURE_METHODS = frozenset({
    "replace", "split", "rsplit", "join", "strip", "lstrip", "rstrip", "startswith", "endswith", "format",
    "format_map", "lower", "upper", "encode", "decode", "splitlines", "partition", "rpartition", "find",
    "rfind", "index", "rindex", "count", "removeprefix", "removesuffix", "zfill", "title", "casefold",
    "center", "ljust", "rjust", "expandtabs", "translate", "maketrans", "capitalize", "swapcase",
    "get", "items", "keys", "values", "copy", "pop", "popitem", "sort", "reverse", "clear",
    "group", "groups", "groupdict", "span", "start", "end", "search", "match", "fullmatch", "findall",
    "finditer", "sub", "subn",
    "read", "readline", "readlines", "write", "writelines", "close", "flush", "seek", "tell", "fileno",
    "read_text", "read_bytes", "exists", "resolve", "absolute", "expanduser", "relative_to", "with_name",
    "with_suffix", "with_stem", "joinpath", "glob", "rglob", "iterdir", "stat", "lstat", "samefile",
    "as_posix", "as_uri", "owner", "is_relative_to",
    "hexdigest", "digest", "isoformat", "strftime", "timestamp",
})
#: Methods that take their arguments into the receiver: the receiver holds what they name.
GROWS = frozenset({"append", "extend", "add", "insert", "update", "setdefault", "appendleft"})
#: Methods of a path that write the file it names; rename and replace also write their argument.
RECEIVER_WRITES = frozenset({"write_text", "write_bytes", "touch", "mkdir", "unlink", "rmdir", "rename",
                             "replace", "symlink_to", "hardlink_to", "chmod", "lchmod"})
MOVES = frozenset({"rename", "replace"})
#: The calls that open a file, and the letters of a mode that writes it.
OPENS = frozenset({"open", "io.open", "codecs.open"})
WRITING_MODE = re.compile(r"[wax+]")


def written_code(code: str) -> str:
    """The source of every part of `code` that can name a file it writes, one part a line, or the
    whole code when it does not parse."""
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return code
    return _Reader(code, tree).written()


class _Reader:
    def __init__(self, code: str, tree: ast.Module) -> None:
        self._code = code
        self._tree = tree
        self._modules: dict[str, str] = {}       # a name bound by an import -> the dotted name it stands for
        self._values: dict[str, list[ast.AST]] = {}
        self._functions: dict[str, ast.FunctionDef | ast.AsyncFunctionDef] = {}
        self._read_bindings()

    def written(self) -> str:
        targets = [t for node in ast.walk(self._tree) if isinstance(node, ast.Call) for t in self._targets(node)]
        seen: set[int] = set()
        parts: list[str] = []
        for target in targets:
            self._sources(target, seen, parts)
        return "\n".join(parts)

    def _read_bindings(self) -> None:
        for node in ast.walk(self._tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    bound = alias.asname or alias.name.split(".")[0]
                    self._modules[bound] = alias.name if alias.asname else bound
            elif isinstance(node, ast.ImportFrom) and node.module:
                for alias in node.names:
                    self._modules[alias.asname or alias.name] = f"{node.module}.{alias.name}"
            elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
                self._functions[node.name] = node
            elif isinstance(node, ast.Assign):
                for target in node.targets:
                    self._bind(target, node.value)
            elif isinstance(node, (ast.AugAssign, ast.AnnAssign)) and node.value is not None:
                self._bind(node.target, node.value)
            elif isinstance(node, ast.NamedExpr):
                self._bind(node.target, node.value)
            elif isinstance(node, (ast.For, ast.AsyncFor, ast.comprehension)):
                self._bind(node.target, node.iter)
            elif isinstance(node, (ast.With, ast.AsyncWith)):
                for item in node.items:
                    if item.optional_vars is not None:
                        self._bind(item.optional_vars, item.context_expr)
        for node in ast.walk(self._tree):
            if not isinstance(node, ast.Call):
                continue
            if isinstance(node.func, ast.Name) and node.func.id in self._functions:
                self._bind_parameters(self._functions[node.func.id], node)
            elif isinstance(node.func, ast.Attribute) and node.func.attr in GROWS:
                for arg in [*node.args, *(k.value for k in node.keywords)]:
                    self._bind(node.func.value, arg)

    def _bind(self, target: ast.AST, value: ast.AST) -> None:
        if isinstance(target, (ast.Tuple, ast.List)):
            for element in target.elts:
                self._bind(element, value)
        elif isinstance(target, ast.Starred):
            self._bind(target.value, value)
        elif isinstance(target, ast.Subscript):
            self._bind(target.value, value)
        elif (key := self._key(target)) is not None:
            self._values.setdefault(key, []).append(value)

    def _bind_parameters(self, function: ast.FunctionDef | ast.AsyncFunctionDef, call: ast.Call) -> None:
        parameters = [*function.args.posonlyargs, *function.args.args]
        for parameter, arg in zip(parameters, call.args):
            self._values.setdefault(parameter.arg, []).append(arg)
        names = {p.arg for p in [*parameters, *function.args.kwonlyargs]}
        for keyword in call.keywords:
            if keyword.arg in names:
                self._values.setdefault(keyword.arg, []).append(keyword.value)
        rest = [*([function.args.vararg] if function.args.vararg else []),
                *([function.args.kwarg] if function.args.kwarg else [])]
        for parameter in rest:
            for arg in [*call.args[len(parameters):], *(k.value for k in call.keywords if k.arg not in names)]:
                self._values.setdefault(parameter.arg, []).append(arg)

    def _key(self, node: ast.AST) -> str | None:
        """`name` or `name.attr...` for a name and the attributes read off it, else None."""
        if isinstance(node, ast.Name):
            return node.id
        if isinstance(node, ast.Attribute) and (base := self._key(node.value)) is not None:
            return f"{base}.{node.attr}"
        return None

    def _dotted(self, node: ast.AST) -> str | None:
        """The dotted name a call's function stands for when it reads off an imported module or is a
        plain name (`osp.relpath` -> `os.path.relpath`), else None (a method of a value)."""
        if isinstance(node, ast.Name):
            return self._modules.get(node.id, node.id)
        if isinstance(node, ast.Attribute):
            root = node
            while isinstance(root, ast.Attribute):
                root = root.value
            if isinstance(root, ast.Name) and root.id in self._modules and root.id not in self._values:
                return f"{self._dotted(node.value)}.{node.attr}"
        return None

    def _targets(self, call: ast.Call) -> list[ast.AST]:
        args = [*call.args, *(k.value for k in call.keywords)]
        name = self._dotted(call.func)
        if name is None and isinstance(call.func, ast.Attribute):
            method, receiver = call.func.attr, call.func.value
            # A string's replace takes the old and the new text; a path's takes where it goes.
            if method in RECEIVER_WRITES and not (method == "replace" and len(call.args) >= 2):
                return [receiver, *(call.args[:1] if method in MOVES else [])]
            if method == "open":
                return [receiver] if _writes(call, 0) else []
            if method in PURE_METHODS or method in GROWS or method.startswith("is_"):
                return []
            return args
        if name in OPENS:
            return [*call.args[:1], *(k.value for k in call.keywords if k.arg == "file")] if _writes(call, 1) else []
        if name in PURE_FUNCTIONS or name in self._functions or (name or "").startswith(
                tuple(f"{m}." for m in PURE_MODULES)):
            return []
        return args

    def _sources(self, node: ast.AST, seen: set[int], parts: list[str]) -> None:
        """Add the source of `node`, and of every value its names were given, to `parts`."""
        if id(node) in seen:
            return
        seen.add(id(node))
        source = ast.get_source_segment(self._code, node)
        if source:
            parts.append(source)
        for inner in ast.walk(node):
            key = self._key(inner) if isinstance(inner, (ast.Name, ast.Attribute)) else None
            for value in self._values.get(key, []) if key else []:
                self._sources(value, seen, parts)
            if isinstance(inner, ast.Call) and isinstance(inner.func, ast.Name) and inner.func.id in self._functions:
                for sub in ast.walk(self._functions[inner.func.id]):
                    if isinstance(sub, ast.Return) and sub.value is not None:
                        self._sources(sub.value, seen, parts)


def _writes(call: ast.Call, position: int) -> bool:
    """Whether an `open` call opens for writing: its mode (at `position`, or `mode=`) holds w, a, x or
    +. A mode that is not a literal may be any of them."""
    mode = next((k.value for k in call.keywords if k.arg == "mode"),
                call.args[position] if len(call.args) > position else None)
    if mode is None:
        return False
    if isinstance(mode, ast.Constant) and isinstance(mode.value, str):
        return bool(WRITING_MODE.search(mode.value))
    return True
