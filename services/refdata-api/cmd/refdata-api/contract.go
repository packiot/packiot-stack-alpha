// contract.go — the datasets.go / endpoints positional contract, extracted
// as structured data for the pre-prod-flip drift gate (task #71).
//
// WHY THIS EXISTS
// ───────────────
// Every dataset (datasets.go) and every fixed /v1/* route (main.go) binds a
// POSITIONAL argument list against a prod pg_proc function, or projects a
// fixed column list from a prod table/view. If prod's function signatures or
// view/table columns DRIFT from what this binary assumes — a function renamed
// _3→_4, an arity change, a dropped column — a prod flip breaks reads SILENTLY
// (500s, or worse, a tenant-fence predicate that no longer resolves). The dba
// verified "zero drift" once by hand; this productizes that into a repeatable
// gate.
//
// This file is the EXTRACTION half: it walks the in-memory registries (single
// source of truth — no re-parsing of a duplicated list) and emits, per backing
// object, the contract we assert against live prod:
//
//   - function  → {name, argc}         : the function must EXIST and accept argc
//     positional args (min_args ≤ argc ≤ nargs,
//     accounting for DEFAULTs and overloads).
//   - relation  → {name, columns}      : the table/view must EXIST and every
//     explicitly-projected column must exist.
//     columns empty ⇒ SELECT * / alias.* ⇒
//     existence-only.
//
// The DIFF half is scripts/refdata-contract-drift-check.sh, which consumes the
// JSON this emits (`refdata-api --dump-contract`) and runs the assertions as
// SELECT-only queries against prod (BEGIN READ ONLY).
//
// FAIL-LOUD PARSING: parseSQL errors on any SQL shape it can't confidently
// classify. A new dataset with an unhandled shape FAILS CI (the golden test /
// --dump-contract), rather than silently escaping the contract check. That
// fail-closed property is the whole point — an un-gated read is the hazard.
package main

import (
	"encoding/json"
	"fmt"
	"io"
	"sort"
	"strings"
)

// contractObject is one backing pg object referenced by a dataset or route.
// A single SQL string can yield several (e.g. a JOIN across two relations, or
// a function plus an ownership-guard relation).
type contractObject struct {
	Ref     string   `json:"ref"`               // dataset name or route path that references this object
	Source  string   `json:"source"`            // "dataset" | "route"
	Kind    string   `json:"kind"`              // "function" | "relation"
	Name    string   `json:"name"`              // public.<name> (schema assumed public)
	ArgC    int      `json:"argc,omitempty"`    // functions: number of positional args passed in the call
	Columns []string `json:"columns,omitempty"` // relations: explicitly-projected columns ([] ⇒ existence-only)
}

// sqlKeywords are tokens that can never be a table alias — used to reject a
// keyword being mis-captured as `FROM <rel> <alias>` when there is no alias.
var sqlKeywords = map[string]bool{
	"where": true, "join": true, "on": true, "using": true, "order": true,
	"group": true, "limit": true, "and": true, "or": true, "as": true,
	"left": true, "inner": true, "cross": true, "full": true, "right": true,
}

// dumpContract writes the full extracted contract (datasets + routes) as a
// stable, sorted JSON array. Invoked by `refdata-api --dump-contract`.
func dumpContract(w io.Writer) error {
	objs, err := extractContract()
	if err != nil {
		return err
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(objs)
}

// extractContract walks both registries and returns every backing object,
// sorted deterministically (ref, then name) so the output is diff-stable.
func extractContract() ([]contractObject, error) {
	var out []contractObject

	// datasets registry (composable /v1/query API)
	names := make([]string, 0, len(datasets))
	for name := range datasets {
		names = append(names, name)
	}
	sort.Strings(names)
	for _, name := range names {
		objs, err := parseSQL(datasets[name].sql)
		if err != nil {
			return nil, fmt.Errorf("dataset %q: %w", name, err)
		}
		for i := range objs {
			objs[i].Ref = name
			objs[i].Source = "dataset"
		}
		out = append(out, objs...)
	}

	// fixed /v1/* routes (main.go endpoints table) — same contract mechanism,
	// same prod surface; a flip breaks these identically, so gate them too.
	for _, ep := range endpoints {
		objs, err := parseSQL(ep.sql)
		if err != nil {
			return nil, fmt.Errorf("route %q: %w", ep.path, err)
		}
		for i := range objs {
			objs[i].Ref = ep.path
			objs[i].Source = "route"
		}
		out = append(out, objs...)
	}

	sort.SliceStable(out, func(i, j int) bool {
		if out[i].Ref != out[j].Ref {
			return out[i].Ref < out[j].Ref
		}
		return out[i].Name < out[j].Name
	})
	return out, nil
}

// parseSQL classifies one SQL string into its backing objects. The SQL shapes
// are regular (all machine-generated from datasets.go / main.go), so a focused
// parser is robust and is locked by the golden test in contract_test.go.
func parseSQL(rawSQL string) ([]contractObject, error) {
	sql := normalizeWS(rawSQL)

	// Locate the primary FROM (the one that closes the first SELECT). Nested
	// FROMs (EXISTS subqueries) come later in the string, so the first FROM is
	// always the primary target.
	fromIdx := indexWord(sql, "FROM", 0)
	if fromIdx < 0 {
		return nil, fmt.Errorf("no FROM clause in %q", rawSQL)
	}
	afterFrom := strings.TrimSpace(sql[fromIdx+len("FROM"):])

	// Case 1: primary target is a set-returning FUNCTION — `name(...)`.
	if name, argc, ok, err := parseFuncCall(afterFrom); err != nil {
		return nil, err
	} else if ok {
		objs := []contractObject{{Kind: "function", Name: name, ArgC: argc}}
		// Guard/secondary relations (e.g. equipments in a perEquipment EXISTS)
		// are existence-only — add every other relation referenced anywhere.
		objs = append(objs, secondaryRelations(sql, map[string]bool{})...)
		return objs, nil
	}

	// Case 2: primary target is a RELATION. Build the alias→relation map from
	// the table-declaration region (FROM … up to the first WHERE), parse the
	// projection list, and attribute each projected column to its relation.
	aliasMap, primary, declRels, err := parseTableDecls(sql, fromIdx)
	if err != nil {
		return nil, err
	}
	projStart := indexWord(sql, "SELECT", 0)
	if projStart < 0 {
		return nil, fmt.Errorf("no SELECT in %q", rawSQL)
	}
	projection := strings.TrimSpace(sql[projStart+len("SELECT") : fromIdx])
	cols, err := parseProjection(projection, aliasMap, primary)
	if err != nil {
		return nil, fmt.Errorf("%w in %q", err, rawSQL)
	}

	// Collect per-relation column lists (relations declared in FROM/JOIN).
	byRel := map[string][]string{}
	for _, rel := range declRels {
		byRel[rel] = nil // ensure declared relations appear even if only *-projected
	}
	for _, c := range cols {
		byRel[c.rel] = append(byRel[c.rel], c.col)
	}
	var objs []contractObject
	seen := map[string]bool{}
	relOrder := append([]string{}, declRels...)
	for _, rel := range relOrder {
		if seen[rel] {
			continue
		}
		seen[rel] = true
		objs = append(objs, contractObject{Kind: "relation", Name: rel, Columns: dedupe(byRel[rel])})
	}
	// Existence-only relations from EXISTS subqueries / anywhere else.
	objs = append(objs, secondaryRelations(sql, seen)...)
	return objs, nil
}

type projCol struct{ rel, col string }

// parseFuncCall detects `name(arglist)` at the start of s (the text right after
// FROM). Returns the function name and the number of top-level arguments.
func parseFuncCall(s string) (name string, argc int, ok bool, err error) {
	i := 0
	for i < len(s) && (isIdentChar(s[i])) {
		i++
	}
	if i == 0 {
		return "", 0, false, nil
	}
	ident := s[:i]
	j := i
	for j < len(s) && s[j] == ' ' {
		j++
	}
	if j >= len(s) || s[j] != '(' {
		return "", 0, false, nil // it's a bare relation, not a call
	}
	// Find the matching close paren and count top-level args.
	depth := 0
	argStart := j + 1
	nonEmpty := false
	count := 0
	for k := j; k < len(s); k++ {
		switch s[k] {
		case '(':
			depth++
		case ')':
			depth--
			if depth == 0 {
				if strings.TrimSpace(s[argStart:k]) != "" {
					nonEmpty = true
				}
				if nonEmpty {
					count++
				}
				return ident, count, true, nil
			}
		case ',':
			if depth == 1 {
				count++
				nonEmpty = true
			}
		default:
			if depth == 1 && s[k] != ' ' {
				nonEmpty = true
			}
		}
	}
	return "", 0, false, fmt.Errorf("unbalanced parens in function call %q", s)
}

// parseTableDecls walks the FROM…WHERE region and returns the alias→relation
// map, the primary (first) relation, and the ordered list of declared
// relations. Handles `FROM rel [alias]`, `JOIN rel [alias] (USING|ON …)`.
func parseTableDecls(sql string, fromIdx int) (aliasMap map[string]string, primary string, rels []string, err error) {
	end := indexWord(sql, "WHERE", fromIdx)
	if end < 0 {
		end = len(sql)
	}
	region := sql[fromIdx:end]
	aliasMap = map[string]string{}
	toks := strings.Fields(region)
	for i := 0; i < len(toks); i++ {
		w := strings.ToLower(toks[i])
		if w == "from" || w == "join" {
			if i+1 >= len(toks) {
				return nil, "", nil, fmt.Errorf("dangling %s", w)
			}
			rel := toks[i+1]
			if !isIdent(rel) {
				return nil, "", nil, fmt.Errorf("unexpected relation token %q", rel)
			}
			rels = append(rels, rel)
			if primary == "" {
				primary = rel
			}
			// optional alias: next token, if it's a bare identifier and not a keyword
			if i+2 < len(toks) {
				cand := toks[i+2]
				if isIdent(cand) && !sqlKeywords[strings.ToLower(cand)] {
					aliasMap[cand] = rel
					i++ // consume alias
				}
			}
		}
	}
	if primary == "" {
		return nil, "", nil, fmt.Errorf("no relation found in FROM region %q", region)
	}
	return aliasMap, primary, rels, nil
}

// parseProjection splits the SELECT list and attributes each column to a
// relation. Bare `col` → primary relation; `alias.col` → alias's relation;
// `*` / `alias.*` → existence-only (no column recorded). Errors on anything
// that isn't a plain (optionally alias-qualified) column, so an expression in a
// projection can't silently drop a column from the contract.
func parseProjection(proj string, aliasMap map[string]string, primary string) ([]projCol, error) {
	items := splitTopLevel(proj)
	var out []projCol
	for _, it := range items {
		it = strings.TrimSpace(it)
		if it == "" {
			continue
		}
		// strip a trailing "AS name"
		if k := indexWord(it, "AS", 0); k >= 0 {
			it = strings.TrimSpace(it[:k])
		}
		if it == "*" {
			continue // existence-only on the (single) primary relation
		}
		if strings.HasSuffix(it, ".*") {
			continue // alias.* → existence-only
		}
		if strings.ContainsAny(it, " ()") {
			return nil, fmt.Errorf("unparseable projection item %q (expression, not a plain column)", it)
		}
		if dot := strings.IndexByte(it, '.'); dot >= 0 {
			alias, col := it[:dot], it[dot+1:]
			rel, ok := aliasMap[alias]
			if !ok {
				return nil, fmt.Errorf("projection references unknown alias %q", alias)
			}
			if !isIdent(col) {
				return nil, fmt.Errorf("non-column projection %q", it)
			}
			out = append(out, projCol{rel: rel, col: col})
			continue
		}
		if !isIdent(it) {
			return nil, fmt.Errorf("non-column projection %q", it)
		}
		out = append(out, projCol{rel: primary, col: it})
	}
	return out, nil
}

// secondaryRelations finds every relation named in a FROM/JOIN anywhere in the
// SQL that isn't already accounted for (skip) and isn't a function call — these
// are existence-only (guard/EXISTS relations like equipments).
func secondaryRelations(sql string, skip map[string]bool) []contractObject {
	var objs []contractObject
	seen := map[string]bool{}
	for _, kw := range []string{"FROM", "JOIN"} {
		pos := 0
		for {
			idx := indexWord(sql, kw, pos)
			if idx < 0 {
				break
			}
			pos = idx + len(kw)
			rest := strings.TrimSpace(sql[pos:])
			// a function call here is not a relation
			if _, _, ok, _ := parseFuncCall(rest); ok {
				continue
			}
			toks := strings.Fields(rest)
			if len(toks) == 0 || !isIdent(toks[0]) {
				continue
			}
			rel := toks[0]
			if skip[rel] || seen[rel] {
				continue
			}
			seen[rel] = true
			objs = append(objs, contractObject{Kind: "relation", Name: rel})
		}
	}
	return objs
}

// ── small lexical helpers ────────────────────────────────────────────────

func normalizeWS(s string) string { return strings.Join(strings.Fields(s), " ") }

func isIdentChar(b byte) bool {
	return b == '_' || (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

func isIdent(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if !isIdentChar(s[i]) {
			return false
		}
	}
	// must start with a letter or underscore
	c := s[0]
	return c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// indexWord finds the byte index of a whole-word token (case-insensitive),
// starting at or after `from`. Whole-word = not flanked by identifier chars.
func indexWord(s, word string, from int) int {
	ls, lw := strings.ToLower(s), strings.ToLower(word)
	for i := from; i+len(lw) <= len(ls); i++ {
		if ls[i:i+len(lw)] != lw {
			continue
		}
		if i > 0 && isIdentChar(ls[i-1]) {
			continue
		}
		if i+len(lw) < len(ls) && isIdentChar(ls[i+len(lw)]) {
			continue
		}
		return i
	}
	return -1
}

// splitTopLevel splits a comma list ignoring commas inside parentheses.
func splitTopLevel(s string) []string {
	var out []string
	depth, start := 0, 0
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '(':
			depth++
		case ')':
			depth--
		case ',':
			if depth == 0 {
				out = append(out, s[start:i])
				start = i + 1
			}
		}
	}
	out = append(out, s[start:])
	return out
}

func dedupe(in []string) []string {
	if len(in) == 0 {
		return nil
	}
	seen := map[string]bool{}
	var out []string
	for _, v := range in {
		if !seen[v] {
			seen[v] = true
			out = append(out, v)
		}
	}
	return out
}
