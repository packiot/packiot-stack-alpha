#!/usr/bin/env python3
"""One-shot wiki restructure (2026-10-13): move pages into the Diátaxis-by-audience
tree and rewrite every relative Markdown link so it still resolves.

Each link is resolved against the page's OLD location, the target is mapped
through MOVES, and the result is re-relativised from the page's NEW location.
Targets outside docs/wiki (the published /adr tree) keep their absolute
site position. Prints the redirect map for mkdocs-redirects.

Usage: scripts/wiki-restructure.py [--dry-run]
"""
import os
import posixpath
import re
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "docs", "wiki")
ROOT = os.path.normpath(ROOT)

# old path (relative to docs/wiki) -> new path. Folders map by prefix.
FOLDER_MOVES = {
    "guide/customize/": "use/customize/",
    "architecture/": "understand/architecture/",
    "subsystems/": "understand/subsystems/",
    "components/": "understand/components/",
}
FILE_MOVES = {
    "guide/setting-up-a-client.md": "use/setting-up-a-client.md",
    "glossary.md": "reference/glossary.md",
    "for-engineers.md": "understand/index.md",
    "operations/local-development.md": "build/develop/local-development.md",
    "operations/branches-and-merging.md": "build/develop/branches-and-merging.md",
    "operations/runbooks.md": "build/operate/runbooks.md",
    "operations/onboarding-a-client.md": "build/operate/onboarding-a-client.md",
    "operations/first-time-box-setup.md": "build/operate/first-time-box-setup.md",
    "operations/dba-guide.md": "build/operate/dba-guide.md",
    "reference/api-endpoints.md": "reference/api/index.md",
}

LINK = re.compile(r"(\]\()([^)\s]+?)(\))")


def new_path(old):
    if old in FILE_MOVES:
        return FILE_MOVES[old]
    for src, dst in FOLDER_MOVES.items():
        if old.startswith(src):
            return dst + old[len(src):]
    return old


def all_pages():
    out = []
    for d, _, files in os.walk(ROOT):
        for f in files:
            if f.endswith(".md"):
                out.append(posixpath.relpath(os.path.join(d, f), ROOT).replace(os.sep, "/"))
    return sorted(out)


def rewrite(text, old_page, new_page):
    def fix(m):
        target = m.group(2)
        if re.match(r"^[a-z]+:", target) or target.startswith(("#", "/")):
            return m.group(0)
        path, sep, frag = target.partition("#")
        if not path.endswith(".md"):
            return m.group(0)
        resolved_old = posixpath.normpath(posixpath.join(posixpath.dirname(old_page), path))
        resolved_new = new_path(resolved_old)
        rel = posixpath.relpath(resolved_new, posixpath.dirname(new_page) or ".")
        return m.group(1) + rel + (sep + frag if sep else "") + m.group(3)

    return LINK.sub(fix, text)


def main():
    dry = "--dry-run" in sys.argv
    pages = all_pages()
    moves = {p: new_path(p) for p in pages}
    contents = {p: open(os.path.join(ROOT, p), encoding="utf-8").read() for p in pages}
    for old, new in moves.items():
        text = rewrite(contents[old], old, new)
        if dry:
            continue
        if old != new:
            os.makedirs(os.path.dirname(os.path.join(ROOT, new)), exist_ok=True)
            subprocess.run(["git", "mv", os.path.join(ROOT, old), os.path.join(ROOT, new)], check=True)
        with open(os.path.join(ROOT, new), "w", encoding="utf-8") as fh:
            fh.write(text)
    print("redirect_maps:")
    for old, new in sorted(moves.items()):
        if old != new:
            print(f"  {old}: {new}")


if __name__ == "__main__":
    main()
