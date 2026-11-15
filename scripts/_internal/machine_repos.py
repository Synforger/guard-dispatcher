"""Every git repository inside an area, as `<area>\t<repo>` lines: the weekly audit lists what it
audits from it. The area is the innermost one holding the repository. A folder named `archive` or
`_archive` is printed as `ARCHIVE\t<folder>` and not walked: what is kept there is no longer
worked in.

    machine_repos.py <corpus-scan.py> [--with-exempt]   (the `_exempt` areas walked too)

The corpus scan is loaded from its file, since its name (`corpus-scan.py`) is not one Python
imports: it is the one place areas.txt is read.
"""
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("corpus_scan", sys.argv[1])
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
try:
    areas = module.load_areas()
except ValueError:
    sys.exit(0)
SKIP = {"node_modules", ".build", "DerivedData", "Pods",
        "third_party", "third-party", "_deps", ".fetchcontent-cache"}
# Repositories kept and no longer worked in: the folder is named in the log and not walked.
ARCHIVES = {"archive", "_archive"}
# `--with-exempt` walks the exempt areas too (doctor.sh --machine: what is exempt is what it looks for).
unwalked = module.UNSCANNED - ({module.EXEMPT} if "--with-exempt" in sys.argv[2:] else set())
scanned = {name: roots for name, roots in areas.items() if name not in unwalked}
def innermost(path):
    holding = [(len(str(root)), name) for name, roots in scanned.items() for root in roots
               if path == str(root) or path.startswith(str(root).rstrip(os.sep) + os.sep)]
    return max(holding)[1] if holding else "-"
for name, roots in scanned.items():
    for root in roots:
        for here, dirs, files in os.walk(root):
            # Someone else's code cloned in (third_party, CMake's fetched sources) is not text the
            # agent wrote, and its history holds other people's words: it is left out
            dirs[:] = [d for d in dirs if d not in SKIP]
            for d in [d for d in dirs if d in ARCHIVES]:
                print(f"ARCHIVE\t{os.path.join(here, d)}")
                dirs.remove(d)
            if ".git" in dirs or ".git" in files:
                print(f"{innermost(here)}\t{here}")
                dirs.remove(".git") if ".git" in dirs else None
