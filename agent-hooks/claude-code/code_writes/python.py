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

A name is read by what it stands for only while nothing rebinds it: a name the code assigns, loops
over, takes as a parameter or binds twice is a call this module does not know (`print = shutil.copy`).
Code that hands on, other than by calling it, something of a module this module does not know as pure
(`key=shutil.copy`, `f = os.system`, `o = os`) or a method that writes its receiver (`key=p.write_text`)
gives itself whole too: a known call may call what it is handed.

The same reading tells outgoing.py whether code reaches past this machine (stays_here): code whose
every call is known as above holds its URLs as text and sends nothing.
"""

from __future__ import annotations

import ast
import re

#: Modules whose functions write no file they are handed a path for (they read, or compute).
PURE_MODULES = ("os.path", "posixpath", "re", "fnmatch", "glob", "json", "shlex", "urllib.parse", "html",
                "textwrap", "string", "math", "datetime", "time", "hashlib", "base64", "collections",
                "itertools", "functools", "difflib", "unicodedata", "operator", "statistics", "decimal",
                "fractions", "uuid", "typing", "dataclasses", "enum", "copy", "pprint", "csv")
#: Functions that write no file they are handed a path for.
PURE_FUNCTIONS = frozenset({
    "print", "len", "str", "repr", "format", "int", "float", "bool", "list", "tuple", "dict", "set",
    "frozenset", "sorted", "reversed", "enumerate", "zip", "min", "max", "sum", "any", "all", "isinstance",
    "issubclass", "abs", "round", "range", "chr", "ord", "hex", "oct", "bin", "id", "hash", "type", "iter",
    "next", "divmod", "pow", "callable", "bytes", "bytearray",
    "pathlib.Path", "pathlib.PurePath", "pathlib.PosixPath", "pathlib.PurePosixPath",
    "os.getcwd", "os.listdir", "os.scandir", "os.walk", "os.stat", "os.lstat", "os.getenv", "os.fspath",
    "os.fsdecode", "os.fsencode", "os.environ.get", "os.access", "os.cpu_count", "os.getpid", "sys.exit",
})
#: Values of `os` and `sys` the code may use: data and the standard streams, whose pure methods are pure
#: (`sys.stdout.write`, `sys.path.insert`). The rest of `sys` is the interpreter's machinery.
MODULE_VALUES = frozenset({"os.environ", "os.sep", "os.linesep", "os.pathsep", "os.curdir", "os.pardir",
                           "os.name", "sys.argv", "sys.stdin", "sys.stdout", "sys.stderr", "sys.platform",
                           "sys.version", "sys.version_info", "sys.maxsize", "sys.byteorder", "sys.path"})
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
#: Modules whose import runs nothing but the module itself: the pure ones and those that work on this
#: machine's files. A call into them that is not pure is still a call this module does not know.
LOCAL_MODULES = (*PURE_MODULES, "__future__", "pathlib", "os", "sys", "io", "codecs", "shutil", "tempfile")
#: Builtins that run, or reach, code or objects the tree does not show: named anywhere (a call, or a
#: value handed on, `sorted(xs, key=eval)`), they make the code one this module does not know.
DYNAMIC = frozenset({"eval", "exec", "compile", "getattr", "setattr", "delattr", "globals", "locals", "vars",
                     "breakpoint", "help"})


def written_code(code: str) -> str:
    """The source of every part of `code` that can name a file it writes, one part a line, or the
    whole code when it does not parse."""
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return code
    return _Reader(code, tree).written()


def stays_here(code: str) -> bool:
    """Whether `code` can do nothing but compute and read or write this machine's files: it parses,
    imports only LOCAL_MODULES, names no DYNAMIC builtin and no dunder, hands on nothing it does not
    know (see the module's docstring), and every call in it is one this module knows (a pure one, an
    `open`, a path's method, a function the code defines and does not rebind). A URL in such code is
    text it holds, not a place it reaches."""
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return False
    return _Reader(code, tree).stays_here()


class _Reader:
    def __init__(self, code: str, tree: ast.Module) -> None:
        self._code = code
        self._tree = tree
        self._modules: dict[str, str] = {}       # a name bound by an import -> the dotted name it stands for
        self._values: dict[str, list[ast.AST]] = {}
        self._functions: dict[str, ast.FunctionDef | ast.AsyncFunctionDef] = {}
        self._rebound: set[str] = set()          # names something other than one def or one import binds
        self._read_bindings()

    def written(self) -> str:
        if self._hands_on_unknown():
            return self._code
        targets = [t for node in ast.walk(self._tree) if isinstance(node, ast.Call) for t in self._targets(node)]
        seen: set[int] = set()
        parts: list[str] = []
        for target in targets:
            self._sources(target, seen, parts)
        return "\n".join(parts)

    def stays_here(self) -> bool:
        if self._hands_on_unknown():
            return False
        for node in ast.walk(self._tree):
            if isinstance(node, ast.Import):
                if not all(_local_module(alias.name) for alias in node.names):
                    return False
            elif isinstance(node, ast.ImportFrom):
                if node.level or not _local_module(node.module or ""):
                    return False
            elif isinstance(node, ast.Name):
                if node.id in DYNAMIC or node.id.startswith("__"):
                    return False
            elif isinstance(node, ast.Attribute):
                if node.attr.startswith("__"):
                    return False
            elif isinstance(node, ast.Call) and not self._known(node):
                return False
        return True

    def _known(self, call: ast.Call) -> bool:
        """Whether `call` is one this module knows: pure, or writing only the files it names."""
        name = self._dotted(call.func)
        if name is None and isinstance(call.func, ast.Attribute):
            method = call.func.attr
            return (method in RECEIVER_WRITES or method == "open" or method in PURE_METHODS
                    or method in GROWS or method.startswith("is_"))
        return name is not None and (name in OPENS or name in self._functions or _pure(name))

    def _hands_on_unknown(self) -> bool:
        """Whether the code names, other than as the function of a call, something of an imported
        module that is not pure, a known value or a constant (`key=os.system`, `o = os`), or a method
        that writes its receiver (`key=p.write_text`)."""
        called: set[int] = set()
        inner: set[int] = set()
        for node in ast.walk(self._tree):
            if isinstance(node, ast.Call):
                function = node.func
                while isinstance(function, ast.Attribute):
                    called.add(id(function))
                    function = function.value
                called.add(id(function))
            elif isinstance(node, ast.Attribute):
                inner.add(id(node.value))
        for node in ast.walk(self._tree):
            if id(node) in called or id(node) in inner or not isinstance(getattr(node, "ctx", None), ast.Load):
                continue
            if isinstance(node, ast.Name) and node.id in self._modules and node.id not in self._rebound:
                name = self._modules[node.id]
            elif isinstance(node, ast.Attribute):
                name = self._dotted(node)
                if name is None:
                    if node.attr in RECEIVER_WRITES or node.attr == "open":
                        return True
                    continue
            else:
                continue
            if not (_pure(name) or name in OPENS or name in MODULE_VALUES or name.rpartition(".")[2].isupper()):
                return True
        return False

    def _read_bindings(self) -> None:
        self._rebound = _rebound_names(self._tree)
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
            return None if node.id in self._rebound else self._modules.get(node.id, node.id)
        if isinstance(node, ast.Attribute):
            root = node
            while isinstance(root, ast.Attribute):
                root = root.value
            if (isinstance(root, ast.Name) and root.id in self._modules and root.id not in self._values
                    and root.id not in self._rebound):
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
        if name is not None and (name in self._functions or _pure(name)):
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


def _pure(name: str) -> bool:
    """Whether the dotted name is a function or a method of a known value that writes no file."""
    owner, _, method = name.rpartition(".")
    return (name in PURE_FUNCTIONS or name.startswith(tuple(f"{m}." for m in PURE_MODULES))
            or (owner in MODULE_VALUES and (method in PURE_METHODS or method in GROWS)))


def _rebound_names(tree: ast.Module) -> set[str]:
    """The names something binds other than one `def` or one import: an assignment, a loop, a `with`,
    an `except`, a parameter, `global`, `del`, a pattern, a class, or a second def or import."""
    names: set[str] = set()
    defined: dict[str, int] = {}
    imported: dict[str, set[str]] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
            names.add(node.id)
        elif isinstance(node, ast.arg):
            names.add(node.arg)
        elif isinstance(node, (ast.Global, ast.Nonlocal)):
            names.update(node.names)
        elif isinstance(node, ast.ExceptHandler) and node.name:
            names.add(node.name)
        elif isinstance(node, (ast.MatchAs, ast.MatchStar)) and node.name:
            names.add(node.name)
        elif isinstance(node, ast.MatchMapping) and node.rest:
            names.add(node.rest)
        elif isinstance(node, ast.ClassDef):
            names.add(node.name)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            defined[node.name] = defined.get(node.name, 0) + 1
        elif isinstance(node, ast.Import):
            for alias in node.names:
                bound = alias.name.split(".")[0]
                imported.setdefault(alias.asname or bound, set()).add(alias.name if alias.asname else bound)
        elif isinstance(node, ast.ImportFrom):
            for alias in node.names:
                imported.setdefault(alias.asname or alias.name, set()).add(f"{node.module}.{alias.name}")
    names.update(name for name, count in defined.items() if count > 1 or name in imported)
    names.update(name for name, sources in imported.items() if len(sources) > 1)
    return names


def _local_module(name: str) -> bool:
    return any(name == m or name.startswith(f"{m}.") for m in LOCAL_MODULES)


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
