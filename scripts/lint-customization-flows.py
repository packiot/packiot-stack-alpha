#!/usr/bin/env python3
"""lint-customization-flows.py — ADR-0009 customization-flow governance gate.

ADR-0009 keeps per-customer customization at the edge as *governed* Node-RED
flows (`clients/<tenant>/customizations/*.json`, see ADR-0021 §1). Those flows
are ALLOWED to hold client-specific display / transform / state-machine logic,
but MUST NOT re-become the Incoplast 1,069-node flow: cleartext credentials,
shell/file bridges doing pipeline work, raw MQTT/Sparkplug ingest, direct writes
to core pipeline tables, or 8,000-line "config-as-code" function nodes.

This script is the CI gate that refuses those. It is deny-list based: unknown
display/transform nodes pass; only the explicitly-forbidden shapes fail. Rules
live in the CONFIG dict below so they stay tunable.

Usage:
    lint-customization-flows.py FLOW_OR_GLOB [FLOW_OR_GLOB ...]

    FLOW_OR_GLOB may be a concrete file or a glob (quote it so the shell does
    not expand it — e.g. 'clients/*/customizations/*.json'). A glob that matches
    nothing is NOT an error (the CI job stays green until B2 adds the first
    customization flow); a concrete path that does not exist IS an error.

Exit codes:
    0  no violations (or no files matched a glob)
    1  one or more governance violations
    2  usage / parse error

Stdlib only — matches the repo's script style (no pip install in CI).
"""

from __future__ import annotations

import glob
import json
import re
import sys

# ─────────────────────────────────────────────────────────────────────────────
# CONFIG — the governance rules. Tunable; this is the whole policy surface.
# ─────────────────────────────────────────────────────────────────────────────
CONFIG = {
    # Rule 3 — oversized function nodes (the 361-line-prep-node / 8,113-line
    # error-dictionary class). A `function` node whose `func` body exceeds this
    # many lines fails. ADR-0009 implementation rule #1 says 200.
    "function_line_cap": 200,

    # Rule 2a — outright-forbidden node *types* (exact match). Shell-outs and
    # file bridges belong in the ERP connector (ADR-0019 G2 rejects them as a
    # standard capability); they are the un-observable failure mode the stack
    # exists to kill.
    "forbidden_node_types": {
        "exec": "shell-out — file/exec bridges belong in the ERP connector (ADR-0019 G2)",
        "file": "file-write bridge — belongs in the ERP connector (ADR-0019 G2)",
        "file in": "file-read bridge — belongs in the ERP connector (ADR-0019 G2)",
    },

    # Rule 2b — raw ingest. Decoding PLC data (raw MQTT subscribe / Sparkplug)
    # is the transformer's job, not a customization flow's. Matched as
    # case-insensitive substrings of the node type.
    "ingest_type_substrings": [
        "mqtt in",
        "sparkplug",
        "mqtt-sparkplug",
        "eon",          # Ignition "Edge of Network" sparkplug node
    ],

    # Rule 4 — deprecated egress retired by the 10.9 cutover (google-iot-core /
    # pubsub-out). Substrings of the node type.
    "deprecated_egress_substrings": [
        "google-iot",
        "google-cloud-pubsub",
        "gcp-pubsub",
        "pubsub out",
    ],

    # Rule 2c — direct DB writes to CORE pipeline tables. A node whose *type*
    # looks like a database client AND whose SQL both writes and names a core
    # table fails. Reads (SELECT) are fine.
    "db_type_substrings": [
        "postgres", "postgresql", "pg", "mysql", "mariadb",
        "mssql", "sqlserver", "oracle", "odbc", "sqlite",
    ],
    "core_tables": [
        "equipment_values",
        "equipment_events",
        "production_orders",
    ],
    "sql_write_verbs": [
        "insert into", "update", "upsert", "merge into",
        "delete from", "copy",
    ],

    # Rule 1 — secret VALUES. A property whose *name* matches one of these
    # patterns and whose value is a literal (not a `secret://…` ref, not an env
    # ref, not empty, not a Node-RED typed non-literal input) fails.
    "secret_key_pattern": (
        r"(?i)(password|passwd|pwd|"
        r"client[_-]?secret|secret|"
        r"api[_-]?key|access[_-]?key|"
        r"auth[_-]?token|(?:^|[_-])token|"
        r"credentials?|"
        r"dsn|conn(?:ection)?[_-]?string|"
        r"private[_-]?key)"
    ),
    # A property value counts as a safe reference (not a literal secret) if it
    # matches any of these.
    "secret_ref_prefixes": ["secret://"],
    # Node-RED typed-input `<prop>Type` values that mean "this is not a string
    # literal" — env var, credential store, or a message/context lookup.
    "nonliteral_input_types": {"env", "cred", "msg", "flow", "global", "jsonata", "bin", "date"},
}

# Env-ref value forms that are safe even without a companion *Type field:
#   ${VAR}  $VAR  env.get('VAR')  process.env.VAR
_ENV_REF_RE = re.compile(
    r"^\s*(?:"
    r"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"
    r"|env\.get\(.*\)"
    r"|process\.env\.[A-Za-z_][A-Za-z0-9_]*"
    r")\s*$"
)

# Unambiguous embedded-credential patterns, scanned in EVERY string value
# regardless of the property name (catches creds hidden in a func body or a
# connection URL). High-confidence only — we do not want false positives.
_EMBEDDED_CRED_PATTERNS = [
    # scheme://user:password@host  — a connection string with inline creds
    (re.compile(r"[a-zA-Z][a-zA-Z0-9+.\-]*://[^/\s:@]+:[^/\s:@]+@"),
     "connection string with embedded credentials"),
    # Google/Firebase API key literal (the leaked AIzaSy… key from the flow)
    (re.compile(r"AIza[0-9A-Za-z_\-]{35}"),
     "Google/Firebase API key literal"),
    # AWS access key id
    (re.compile(r"AKIA[0-9A-Z]{16}"),
     "AWS access key id literal"),
    # inline `password: 'literal'` / `token = "literal"` inside JS/text
    (re.compile(
        r"""(?ix)\b(password|passwd|pwd|secret|api[_-]?key|token)\b\s*[:=]\s*"""
        r"""['"]([^'"]{3,})['"]"""),
     "inline credential literal"),
]

_SECRET_KEY_RE = re.compile(CONFIG["secret_key_pattern"])


class Violation:
    __slots__ = ("rule", "flow", "node_id", "node_name", "node_type", "detail")

    def __init__(self, rule, flow, node, detail):
        self.rule = rule
        self.flow = flow
        self.node_id = node.get("id", "?")
        self.node_name = node.get("name", "") or "(unnamed)"
        self.node_type = node.get("type", "?")
        self.detail = detail

    def __str__(self):
        return (
            f"[{self.rule}] {self.flow}: node {self.node_id} "
            f"({self.node_name}, type={self.node_type})\n"
            f"        {self.detail}"
        )


# ─────────────────────────────────────────────────────────────────────────────
# Value classification helpers
# ─────────────────────────────────────────────────────────────────────────────
def _is_safe_secret_value(value: str) -> bool:
    """A property value is safe if it is empty, a secret:// ref, or an env ref."""
    v = value.strip()
    if v == "":
        return True
    for prefix in CONFIG["secret_ref_prefixes"]:
        if v.startswith(prefix):
            return True
    if _ENV_REF_RE.match(v):
        return True
    return False


def _iter_string_props(obj, parent_key=None):
    """Yield (parent_key, value) for every string reachable in a node dict.

    parent_key is the dict key the string sits under (used for name-based secret
    detection); for strings inside lists it is the enclosing dict's key.
    """
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(v, str):
                yield k, v
            else:
                yield from _iter_string_props(v, parent_key=k)
    elif isinstance(obj, list):
        for item in obj:
            yield from _iter_string_props(item, parent_key=parent_key)


def _input_is_nonliteral(node: dict, key: str) -> bool:
    """True if Node-RED's companion `<key>Type` marks this input as non-literal
    (env var, credential, msg/flow/global lookup, …)."""
    t = node.get(key + "Type")
    return isinstance(t, str) and t in CONFIG["nonliteral_input_types"]


# ─────────────────────────────────────────────────────────────────────────────
# Per-node rule checks
# ─────────────────────────────────────────────────────────────────────────────
def check_secret_values(node: dict, flow: str, out: list) -> None:
    # Name-based: a secret-ish property holding a literal value.
    for key, value in _iter_string_props(node):
        # Skip Node-RED typed-input companions (`<prop>Type`): their value is a
        # type tag like "env"/"cred", not the secret itself — and "api_keyType"
        # would otherwise match the secret-key pattern.
        if key.endswith("Type"):
            continue
        if _SECRET_KEY_RE.search(key) and not _input_is_nonliteral(node, key):
            if not _is_safe_secret_value(value):
                out.append(Violation(
                    "SECRET_VALUE", flow, node,
                    f"property '{key}' holds a literal secret value "
                    f"({_redact(value)}); use a secret:// reference or an env ref.",
                ))
    # Content-based: unambiguous credentials embedded anywhere (func body, URL).
    for _key, value in _iter_string_props(node):
        if _is_safe_secret_value(value):
            continue
        for pat, label in _EMBEDDED_CRED_PATTERNS:
            m = pat.search(value)
            if m:
                out.append(Violation(
                    "SECRET_VALUE", flow, node,
                    f"{label} found in value ({_redact(value)}); "
                    f"externalize to a secret:// reference.",
                ))
                break  # one finding per string is enough


def check_node_type(node: dict, flow: str, out: list) -> None:
    ntype = (node.get("type") or "").strip()
    ltype = ntype.lower()

    # Rule 2a — forbidden exact types (exec / file bridges).
    if ntype in CONFIG["forbidden_node_types"]:
        out.append(Violation(
            "FORBIDDEN_NODE", flow, node,
            CONFIG["forbidden_node_types"][ntype],
        ))
        return

    # Rule 2b — raw ingest (mqtt in / sparkplug decode).
    for sub in CONFIG["ingest_type_substrings"]:
        if sub in ltype:
            out.append(Violation(
                "INGEST_NODE", flow, node,
                f"raw ingest node (type matches '{sub}'); PLC/MQTT/Sparkplug "
                f"decode belongs in the edge-transformer, not a customization flow.",
            ))
            return

    # Rule 4 — deprecated egress (google-iot-core / pubsub-out).
    for sub in CONFIG["deprecated_egress_substrings"]:
        if sub in ltype:
            out.append(Violation(
                "DEPRECATED_EGRESS", flow, node,
                f"deprecated egress node (type matches '{sub}'); this egress was "
                f"retired by the 10.9 cutover.",
            ))
            return


def check_db_core_write(node: dict, flow: str, out: list) -> None:
    ltype = (node.get("type") or "").lower()
    # Is this a database node? Match whole-word-ish to avoid 'pg' hitting inside
    # unrelated types.
    is_db = any(
        re.search(r"(?:^|[^a-z])" + re.escape(sub) + r"(?:[^a-z]|$)", ltype)
        for sub in CONFIG["db_type_substrings"]
    )
    if not is_db:
        return
    # Collect all SQL-ish text from the node.
    blob = " \n ".join(v for _k, v in _iter_string_props(node)).lower()
    if not any(verb in blob for verb in CONFIG["sql_write_verbs"]):
        return
    for table in CONFIG["core_tables"]:
        if re.search(r"(?:^|[^a-z_])" + re.escape(table) + r"(?:[^a-z_]|$)", blob):
            out.append(Violation(
                "DBWRITE_CORE", flow, node,
                f"database node writes to core pipeline table '{table}'; "
                f"customization flows must not write raw pipeline tables "
                f"(that is the transformer's job).",
            ))
            return


def check_function_size(node: dict, flow: str, out: list) -> None:
    if (node.get("type") or "") != "function":
        return
    func = node.get("func")
    if not isinstance(func, str):
        return
    lines = func.count("\n") + 1 if func else 0
    cap = CONFIG["function_line_cap"]
    if lines > cap:
        out.append(Violation(
            "OVERSIZED_FUNCTION", flow, node,
            f"function body is {lines} lines (cap {cap}); split it or move "
            f"config-as-code out to client.yaml / data files.",
        ))


NODE_CHECKS = [
    check_secret_values,
    check_node_type,
    check_db_core_write,
    check_function_size,
]


def _redact(value: str, keep: int = 4) -> str:
    v = value.strip().replace("\n", "\\n")
    if len(v) <= keep:
        return "***"
    return v[:keep] + "…***"


# ─────────────────────────────────────────────────────────────────────────────
# Flow loading + top-level driver
# ─────────────────────────────────────────────────────────────────────────────
def load_nodes(path: str):
    with open(path, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    # Node-RED exports are a bare list of nodes; some tools wrap them in
    # {"flows": [...]} or {"rev":..., "flows":[...]}.
    if isinstance(data, dict):
        data = data.get("flows", [])
    if not isinstance(data, list):
        raise ValueError("flow file is neither a node list nor a {'flows': [...]} object")
    return [n for n in data if isinstance(n, dict)]


def lint_flow(path: str) -> list:
    nodes = load_nodes(path)
    violations: list = []
    for node in nodes:
        for check in NODE_CHECKS:
            check(node, path, violations)
    return violations


def expand_args(args):
    """Turn positional args (files or globs) into a concrete file list.

    - A glob (has *?[ ) that matches nothing → silently skipped (empty is OK).
    - A concrete path that does not exist → hard error (exit 2).
    """
    files, missing = [], []
    for arg in args:
        if glob.has_magic(arg):
            files.extend(sorted(glob.glob(arg, recursive=True)))
        else:
            files.append(arg)  # validated for existence below
    # de-dup, preserve order
    seen, uniq = set(), []
    for f in files:
        if f not in seen:
            seen.add(f)
            uniq.append(f)
    for f in uniq:
        try:
            open(f, "rb").close()
        except OSError:
            missing.append(f)
    return uniq, missing


def main(argv):
    args = argv[1:]
    if not args:
        print(__doc__.strip().splitlines()[0], file=sys.stderr)
        print("usage: lint-customization-flows.py FLOW_OR_GLOB [FLOW_OR_GLOB ...]",
              file=sys.stderr)
        return 2

    files, missing = expand_args(args)
    if missing:
        for f in missing:
            print(f"error: file not found: {f}", file=sys.stderr)
        return 2

    if not files:
        print("no customization flows matched — nothing to lint (OK).")
        return 0

    all_violations = []
    for path in files:
        try:
            all_violations.extend(lint_flow(path))
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            print(f"error: cannot lint {path}: {exc}", file=sys.stderr)
            return 2

    if not all_violations:
        n = len(files)
        print(f"customization-flow lint: OK — {n} flow file{'s' if n != 1 else ''}, "
              f"0 violations.")
        return 0

    print(f"customization-flow lint: FAILED — {len(all_violations)} violation(s):\n",
          file=sys.stderr)
    for v in all_violations:
        print(str(v), file=sys.stderr)
        print(file=sys.stderr)
    # Rule tally
    tally = {}
    for v in all_violations:
        tally[v.rule] = tally.get(v.rule, 0) + 1
    summary = ", ".join(f"{k}={n}" for k, n in sorted(tally.items()))
    print(f"summary: {summary}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
