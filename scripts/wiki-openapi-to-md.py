#!/usr/bin/env python3
"""Render the committed OpenAPI documents into static wiki pages.

    scripts/wiki-openapi-to-md.py <spec-dir> <out-dir>

Reads <spec-dir>/<api>.openapi.json (written by `make openapi`) and writes one
Markdown page per API into <out-dir> (the wiki build-staging tree, never the
repo), plus nothing else: reference/api/index.md is hand-written and links them.

Why static Markdown and not an embedded Swagger UI: the wiki is served behind
the SSO gate with no CDN at runtime (see wiki/mkdocs.yml), it is searchable,
and it builds under `mkdocs --strict`. The interactive, read-only Swagger UI is
the API portal at https://api.staging.packiot.app/docs/ (SSO); each page links
to it. stdlib only.
"""
import json
import os
import re
import sys

PORTAL = "https://api.staging.packiot.app/docs/"
METHODS = ("get", "put", "post", "delete", "patch", "head", "options")

# Portal dropdown names (terraform/staging/user_data/nginx_setup.sh) per spec file.
PORTAL_NAMES = {
    "edge-api": "edge-api (control plane)",
    "read-api": "read-api (refdata / query)",
    "barcode-service": "barcode-service (scan)",
    "sparkplug-agent": "sparkplug-agent (HTTP tag ingest)",
    "onboard-api": "onboard API (sparkplug-decoder)",
    "ingest-shim": "ingest-shim",
    "operator-gateway": "operator-gateway",
}


def cell(text):
    """Make text safe for a one-line Markdown table cell."""
    if text is None:
        return ""
    text = str(text).replace("\r", "")
    text = re.sub(r"\s*\n\s*", " ", text)
    return text.replace("|", "\\|")


def demote(md, by=2):
    """Push headings inside descriptions below the page's own structure."""
    return re.sub(r"(?m)^(#{1,4}) ", lambda m: "#" * min(6, len(m.group(1)) + by) + " ", md or "")


def code(obj, lang="json"):
    body = obj if isinstance(obj, str) else json.dumps(obj, indent=2, ensure_ascii=False)
    return f"```{lang}\n{body}\n```"


def indent(text, n=4):
    pad = " " * n
    return "\n".join(pad + line if line else line for line in text.split("\n"))


class Spec:
    def __init__(self, doc):
        self.doc = doc
        self.components = doc.get("components", {})

    def deref(self, obj, depth=0):
        while isinstance(obj, dict) and "$ref" in obj and depth < 20:
            parts = obj["$ref"].lstrip("#/").split("/")
            node = self.doc
            for p in parts:
                node = node.get(p, {}) if isinstance(node, dict) else {}
            obj, depth = node, depth + 1
        return obj

    def type_of(self, schema):
        schema = schema or {}
        ref = schema.get("$ref", "")
        name = ref.rsplit("/", 1)[-1] if ref else ""
        s = self.deref(schema)
        if not isinstance(s, dict):
            return "object"
        for combo in ("oneOf", "anyOf", "allOf"):
            if combo in s:
                return f" {'&' if combo == 'allOf' else 'or'} ".join(self.type_of(x) for x in s[combo])
        t = s.get("type", "object" if "properties" in s else "")
        if isinstance(t, list):
            t = " or ".join(t)
        if t == "array":
            return f"array of {self.type_of(s.get('items', {}))}"
        if s.get("enum"):
            vals = ", ".join(f"`{v}`" for v in s["enum"][:8])
            return f"{t or 'value'} ({vals}{', …' if len(s['enum']) > 8 else ''})"
        if s.get("format"):
            t = f"{t} ({s['format']})"
        return name or t or "any"

    def examples(self, media):
        media = self.deref(media) or {}
        out = []
        if "example" in media:
            out.append(("Example", media["example"]))
        for key, ex in (media.get("examples") or {}).items():
            ex = self.deref(ex)
            if isinstance(ex, dict) and "value" in ex:
                out.append((ex.get("summary") or key, ex["value"]))
        if not out:
            schema = self.deref(media.get("schema", {}))
            if isinstance(schema, dict) and "example" in schema:
                out.append(("Example", schema["example"]))
        return out


def properties_table(spec, schema):
    s = spec.deref(schema)
    if isinstance(s, dict) and s.get("type") == "array":
        s = spec.deref(s.get("items", {}))
    if not isinstance(s, dict):
        return ""
    props = dict(s.get("properties") or {})
    for part in s.get("allOf", []):
        props.update((spec.deref(part) or {}).get("properties") or {})
    if not props:
        return ""
    required = set(s.get("required") or [])
    rows = ["| Field | Type | Required | Description |", "|---|---|---|---|"]
    for name, p in props.items():
        pd = spec.deref(p) or {}
        desc = pd.get("description", "") if isinstance(pd, dict) else ""
        rows.append(f"| `{cell(name)}` | {cell(spec.type_of(p))} | {'yes' if name in required else ''} | {cell(desc)} |")
    return "\n".join(rows)


def render_operation(spec, method, path, op, path_params):
    lines = []
    title = op.get("summary") or f"{method.upper()} {path}"
    lines.append(f"### {cell(title)}")
    lines.append("")
    badge = " · **deprecated**" if op.get("deprecated") else ""
    lines.append(f"`{method.upper()} {path}`{badge}")
    if op.get("operationId"):
        lines.append(f"<small>operationId: `{op['operationId']}`</small>")
    lines.append("")
    if op.get("description"):
        lines += [demote(op["description"]).strip(), ""]

    security = op.get("security", spec.doc.get("security"))
    if security is not None:
        if security == [] or all(not s for s in security):
            lines += ["**Auth:** none (public).", ""]
        else:
            alts = [" + ".join(f"`{k}`" for k in s) for s in security if s]
            lines += [f"**Auth:** {' or '.join(alts)}", ""]

    params = [spec.deref(p) for p in path_params + op.get("parameters", [])]
    if params:
        lines += ["**Parameters**", "", "| Name | In | Type | Required | Description |", "|---|---|---|---|---|"]
        for p in params:
            desc = p.get("description", "")
            if "example" in p:
                desc = f"{desc} Example: `{cell(json.dumps(p['example'], ensure_ascii=False))}`".strip()
            lines.append(
                f"| `{cell(p.get('name'))}` | {p.get('in', '')} | {cell(spec.type_of(p.get('schema', {})))} "
                f"| {'yes' if p.get('required') else ''} | {cell(desc)} |"
            )
        lines.append("")

    body = spec.deref(op.get("requestBody", {}))
    if body:
        lines += ["**Request body**" + (" (required)" if body.get("required") else ""), ""]
        if body.get("description"):
            lines += [demote(body["description"]).strip(), ""]
        for ctype, media in (body.get("content") or {}).items():
            media = spec.deref(media)
            lines.append(f"`{ctype}` — {cell(spec.type_of(media.get('schema', {})))}")
            lines.append("")
            table = properties_table(spec, media.get("schema", {}))
            if table:
                lines += [table, ""]
            for label, value in spec.examples(media):
                lines.append(f'??? example "{cell(label)}"')
                lines += [indent(code(value, "json" if not isinstance(value, str) else "text")), ""]

    responses = op.get("responses") or {}
    if responses:
        lines += ["**Responses**", "", "| Status | Description | Content |", "|---|---|---|"]
        for status, resp in responses.items():
            r = spec.deref(resp) or {}
            ctypes = ", ".join(f"`{c}`" for c in (r.get("content") or {}))
            lines.append(f"| `{status}` | {cell(r.get('description', ''))} | {ctypes} |")
        lines.append("")
        for status, resp in responses.items():
            r = spec.deref(resp) or {}
            for ctype, media in (r.get("content") or {}).items():
                for label, value in spec.examples(media):
                    name = f"{status} {label}" if label != "Example" else f"{status} response"
                    lines.append(f'??? example "{cell(name)} ({ctype})"')
                    lang = "json" if not isinstance(value, str) else "text"
                    lines += [indent(code(value, lang)), ""]
    lines.append("")
    return lines


def render(name, doc):
    spec = Spec(doc)
    info = doc.get("info", {})
    title = info.get("title", name)
    out = [
        "---",
        f"title: \"{title} — API reference\"",
        "layer: 4",
        "owner_area: serving",
        "generated: true",
        "---",
        f"# {title}",
        "",
        "> **Reference · generated** from `docs/api/openapi/"
        f"{name}.openapi.json` at wiki build time. Do not edit this page; change the spec in "
        "code and run `make openapi`. "
        f"Interactive, read-only Swagger UI (SSO): [API portal]({PORTAL}) → *{PORTAL_NAMES.get(name, name)}*.",
        f"> Up: [API reference](index.md) · Version `{info.get('version', '')}` · OpenAPI `{doc.get('openapi', '')}`",
        "",
    ]
    if info.get("description"):
        out += ["## Overview", "", demote(info["description"], by=1).strip(), ""]

    servers = doc.get("servers") or []
    if servers:
        out += ["## Servers", "", "| URL | Description |", "|---|---|"]
        out += [f"| `{cell(s.get('url'))}` | {cell(s.get('description', ''))} |" for s in servers]
        out.append("")

    schemes = (spec.components.get("securitySchemes") or {})
    if schemes:
        out += ["## Authentication", "", "| Scheme | Type | Where | Description |", "|---|---|---|---|"]
        for key, sch in schemes.items():
            sch = spec.deref(sch)
            where = sch.get("in", "") + (f" `{sch['name']}`" if sch.get("name") else "")
            if sch.get("type") == "http":
                where = f"`Authorization: {str(sch.get('scheme', '')).title()} …`"
            out.append(f"| `{key}` | {sch.get('type', '')} | {cell(where)} | {cell(sch.get('description', ''))} |")
        out.append("")

    tag_desc = {t["name"]: t.get("description", "") for t in doc.get("tags", [])}
    order = [t["name"] for t in doc.get("tags", [])]
    grouped = {}
    for path, item in (doc.get("paths") or {}).items():
        item = spec.deref(item)
        path_params = item.get("parameters", [])
        for method in METHODS:
            if method in item:
                op = item[method]
                tag = (op.get("tags") or ["Other"])[0]
                grouped.setdefault(tag, []).append((method, path, op, path_params))
    for tag in order + sorted(t for t in grouped if t not in order):
        if tag not in grouped:
            continue
        out += [f"## {cell(tag)}", ""]
        if tag_desc.get(tag):
            out += [demote(tag_desc[tag]).strip(), ""]
        out += ["| Method | Path | Summary |", "|---|---|---|"]
        out += [f"| `{m.upper()}` | `{cell(p)}` | {cell(o.get('summary', ''))} |" for m, p, o, _ in grouped[tag]]
        out.append("")
        for method, path, op, pp in grouped[tag]:
            out += render_operation(spec, method, path, op, pp)
    return "\n".join(out).rstrip() + "\n"


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    src, dst = sys.argv[1], sys.argv[2]
    os.makedirs(dst, exist_ok=True)
    for fname in sorted(os.listdir(src)):
        if not fname.endswith(".openapi.json"):
            continue
        name = fname[: -len(".openapi.json")]
        with open(os.path.join(src, fname), encoding="utf-8") as fh:
            doc = json.load(fh)
        with open(os.path.join(dst, f"{name}.md"), "w", encoding="utf-8") as fh:
            fh.write(render(name, doc))
        ops = sum(1 for item in doc.get("paths", {}).values() for m in METHODS if m in item)
        print(f"  reference/api/{name}.md ({ops} operations)")


if __name__ == "__main__":
    main()
