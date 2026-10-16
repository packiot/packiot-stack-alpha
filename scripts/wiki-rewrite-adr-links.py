#!/usr/bin/env python3
"""Rewrite ADR links that point outside the published wiki into GitHub links.

ADRs are repo documents: they link to compose files, workflows, submodules and design
notes that are not part of the static site. The build copies docs/adr/*.md into /adr so
the wiki can link to them; this pass keeps those pages link-clean under `mkdocs --strict`
by pointing every relative link whose target is not a published ADR at the same path on
GitHub (branch from $WIKI_GITHUB_REF, default staging). Same-page anchors are left alone.

usage: wiki-rewrite-adr-links.py <site-adr-dir> <repo-root>
"""
import os, re, sys

site_adr, root = sys.argv[1], sys.argv[2]
ref = os.environ.get("WIKI_GITHUB_REF", "staging")
base = f"https://github.com/packiot/packiot-stack-alpha/blob/{ref}/"
published = set(os.listdir(site_adr))
link = re.compile(r"(\]\()([^)\s]+)(\))")

def fix(target: str) -> str:
    if target.startswith(("http://", "https://", "mailto:", "#")):
        return target
    path, _, anchor = target.partition("#")
    if not path:
        return target
    if "/" not in path and path in published:
        return target  # another published ADR
    repo_path = os.path.normpath(os.path.join("docs/adr", path))
    if repo_path.startswith(".."):
        return path  # points outside the repo (e.g. a personal notes vault): drop the link target
    return base + repo_path + (f"#{anchor}" if anchor else "")

for name in sorted(published):
    if not name.endswith(".md"):
        continue
    p = os.path.join(site_adr, name)
    src = open(p, encoding="utf-8").read()
    out = link.sub(lambda m: m.group(1) + fix(m.group(2)) + m.group(3), src)
    if out != src:
        open(p, "w", encoding="utf-8").write(out)
