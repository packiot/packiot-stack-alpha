package onboardapi

// openapi_completeness_test.go — the documentation COMPLETENESS gate.
//
// The drift test (openapi_test.go) proves every route is described; this one
// proves every description is usable by someone who has never read the code:
// an integrator in the Swagger portal (/docs/) or the wiki export
// (docs/api/openapi/). Each Go module carries its own copy of this file on
// purpose (modules are independent; no cross-module test dependency). Keep the
// copies identical apart from the package clause and the test at the bottom.

import (
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"testing"
)

// openAPIMaxSummaryWords keeps operation summaries scannable in the portal's
// collapsed list view.
const openAPIMaxSummaryWords = 10

var openAPIHTTPMethods = []string{"get", "put", "post", "delete", "options", "head", "patch", "trace"}

// openAPICompletenessProblems returns one human-readable line per gap, each
// naming the operation ("POST /v1/x (opId)") and the missing field. Empty means
// the document is complete. rawSpec is the JSON document.
func openAPICompletenessProblems(rawSpec []byte) []string {
	var doc map[string]any
	if err := json.Unmarshal(rawSpec, &doc); err != nil {
		return []string{"spec is not valid JSON: " + err.Error()}
	}
	c := &openAPIChecker{doc: doc}
	c.run()
	sort.Strings(c.problems)
	return c.problems
}

type openAPIChecker struct {
	doc      map[string]any
	problems []string
}

func (c *openAPIChecker) addf(format string, args ...any) {
	c.problems = append(c.problems, fmt.Sprintf(format, args...))
}

// resolve follows a local "#/..." $ref (repeatedly). Non-local or broken refs
// are reported and return nil.
func (c *openAPIChecker) resolve(where string, v any) map[string]any {
	m, _ := v.(map[string]any)
	for i := 0; m != nil && i < 16; i++ {
		ref, ok := m["$ref"].(string)
		if !ok {
			return m
		}
		if !strings.HasPrefix(ref, "#/") {
			c.addf("%s: non-local $ref %q", where, ref)
			return nil
		}
		var cur any = c.doc
		for _, part := range strings.Split(strings.TrimPrefix(ref, "#/"), "/") {
			part = strings.ReplaceAll(strings.ReplaceAll(part, "~1", "/"), "~0", "~")
			next, _ := cur.(map[string]any)
			cur = next[part]
		}
		target, _ := cur.(map[string]any)
		if target == nil {
			c.addf("%s: broken $ref %q", where, ref)
			return nil
		}
		// A $ref with sibling keys (3.1) keeps the siblings: they override.
		if len(m) > 1 {
			merged := map[string]any{}
			for k, v := range target {
				merged[k] = v
			}
			for k, v := range m {
				if k != "$ref" {
					merged[k] = v
				}
			}
			m = merged
			continue
		}
		m = target
	}
	return m
}

func hasNonEmptyString(m map[string]any, key string) bool {
	s, _ := m[key].(string)
	return strings.TrimSpace(s) != ""
}

// hasExample: an `example`, a non-empty `examples` (map in media types and
// parameters, array in 3.1 schemas), on the object itself or on its schema.
func (c *openAPIChecker) hasExample(where string, m map[string]any) bool {
	if m == nil {
		return false
	}
	if _, ok := m["example"]; ok {
		return true
	}
	switch ex := m["examples"].(type) {
	case map[string]any:
		if len(ex) > 0 {
			return true
		}
	case []any:
		if len(ex) > 0 {
			return true
		}
	}
	if s, ok := m["schema"]; ok {
		return c.hasExample(where, c.resolve(where, s))
	}
	if _, ok := m["const"]; ok {
		return true
	}
	return false
}

func (c *openAPIChecker) run() {
	declared := map[string]bool{}
	tags, _ := c.doc["tags"].([]any)
	for _, t := range tags {
		tm, _ := t.(map[string]any)
		name, _ := tm["name"].(string)
		declared[name] = true
		if !hasNonEmptyString(tm, "description") {
			c.addf("top-level tag %q: missing description", name)
		}
	}
	info, _ := c.doc["info"].(map[string]any)
	if !hasNonEmptyString(info, "description") {
		c.addf("info: missing description")
	}

	opIDs := map[string]string{}
	paths, _ := c.doc["paths"].(map[string]any)
	for _, path := range sortedMapKeys(paths) {
		item, _ := paths[path].(map[string]any)
		var shared []any
		if p, ok := item["parameters"].([]any); ok {
			shared = p
		}
		for _, method := range openAPIHTTPMethods {
			raw, ok := item[method]
			if !ok {
				continue
			}
			op, _ := raw.(map[string]any)
			id, _ := op["operationId"].(string)
			name := fmt.Sprintf("%s %s (%s)", strings.ToUpper(method), path, id)
			if id == "" {
				c.addf("%s: missing operationId", name)
			} else if prev, dup := opIDs[id]; dup {
				c.addf("%s: operationId duplicates %s", name, prev)
			}
			opIDs[id] = name
			c.checkOperation(name, op, shared, declared)
		}
	}
}

func (c *openAPIChecker) checkOperation(name string, op map[string]any, shared []any, declared map[string]bool) {
	if !hasNonEmptyString(op, "summary") {
		c.addf("%s: missing summary", name)
	} else if n := len(strings.Fields(op["summary"].(string))); n > openAPIMaxSummaryWords {
		c.addf("%s: summary has %d words (max %d)", name, n, openAPIMaxSummaryWords)
	}
	if !hasNonEmptyString(op, "description") {
		c.addf("%s: missing description", name)
	}
	tags, _ := op["tags"].([]any)
	if len(tags) == 0 {
		c.addf("%s: missing tags", name)
	}
	for _, t := range tags {
		if s, _ := t.(string); !declared[s] {
			c.addf("%s: tag %q is not declared in top-level tags", name, s)
		}
	}

	params := append([]any{}, shared...)
	if p, ok := op["parameters"].([]any); ok {
		params = append(params, p...)
	}
	for _, p := range params {
		pm := c.resolve(name+" parameter", p)
		if pm == nil {
			continue
		}
		pn := fmt.Sprintf("%s: parameter %q (in %v)", name, pm["name"], pm["in"])
		if !hasNonEmptyString(pm, "description") {
			c.addf("%s: missing description", pn)
		}
		if !c.hasExample(pn, pm) {
			c.addf("%s: missing example", pn)
		}
		if s, ok := pm["schema"]; ok {
			c.checkSchemaProps(pn, s, map[string]bool{})
		}
	}

	if rb, ok := op["requestBody"]; ok {
		body := c.resolve(name+" requestBody", rb)
		content, _ := body["content"].(map[string]any)
		if len(content) == 0 {
			c.addf("%s: requestBody has no content", name)
		}
		for _, ct := range sortedMapKeys(content) {
			mt, _ := content[ct].(map[string]any)
			where := fmt.Sprintf("%s: requestBody %s", name, ct)
			if !c.hasExample(where, mt) {
				c.addf("%s: missing example", where)
			}
			if s, ok := mt["schema"]; ok {
				c.checkSchemaProps(where, s, map[string]bool{})
			}
		}
	}

	responses, _ := op["responses"].(map[string]any)
	ok2xx := false
	for _, code := range sortedMapKeys(responses) {
		resp := c.resolve(name+" response "+code, responses[code])
		if resp == nil {
			continue
		}
		where := fmt.Sprintf("%s: response %s", name, code)
		if !hasNonEmptyString(resp, "description") {
			c.addf("%s: missing description", where)
		}
		content, _ := resp["content"].(map[string]any)
		if strings.HasPrefix(code, "2") {
			for _, ct := range sortedMapKeys(content) {
				mt, _ := content[ct].(map[string]any)
				if _, hasSchema := mt["schema"]; hasSchema && c.hasExample(where, mt) {
					ok2xx = true
				}
			}
		}
		for _, ct := range sortedMapKeys(content) {
			mt, _ := content[ct].(map[string]any)
			if s, ok := mt["schema"]; ok {
				c.checkSchemaProps(fmt.Sprintf("%s %s", where, ct), s, map[string]bool{})
			}
		}
	}
	if !ok2xx {
		c.addf("%s: no 2xx response with both a schema and an example", name)
	}
}

// checkSchemaProps demands a description on every named property, walking
// nested objects, arrays and compositions. A property that is a bare $ref is
// satisfied by the referenced schema's own description.
func (c *openAPIChecker) checkSchemaProps(where string, raw any, seen map[string]bool) {
	if m, ok := raw.(map[string]any); ok {
		if ref, ok := m["$ref"].(string); ok {
			if seen[ref] {
				return
			}
			seen[ref] = true
			defer delete(seen, ref)
		}
	}
	s := c.resolve(where, raw)
	if s == nil {
		return
	}
	props, _ := s["properties"].(map[string]any)
	for _, pn := range sortedMapKeys(props) {
		p := c.resolve(where+"."+pn, props[pn])
		if p == nil {
			continue
		}
		if !hasNonEmptyString(p, "description") {
			c.addf("%s: property %q missing description", where, pn)
		}
		c.checkSchemaProps(where+"."+pn, props[pn], seen)
	}
	for _, key := range []string{"items", "additionalProperties"} {
		if sub, ok := s[key].(map[string]any); ok {
			c.checkSchemaProps(where+"."+key, sub, seen)
		}
	}
	for _, key := range []string{"oneOf", "anyOf", "allOf"} {
		subs, _ := s[key].([]any)
		for i, sub := range subs {
			c.checkSchemaProps(fmt.Sprintf("%s.%s[%d]", where, key, i), sub, seen)
		}
	}
}

func sortedMapKeys(m map[string]any) []string {
	out := make([]string, 0, len(m))
	for k := range m {
		out = append(out, k)
	}
	sort.Strings(out)
	return out
}

func reportOpenAPIProblems(t *testing.T, problems []string) {
	t.Helper()
	for _, p := range problems {
		t.Error(p)
	}
	if len(problems) > 0 {
		t.Logf("%d documentation gap(s) — see the spec's completeness rules in openapi_completeness_test.go", len(problems))
	}
}

// The gate must actually bite: a deliberately thin operation yields one named
// problem per missing field.
func TestOpenAPICompletenessCheckerCatchesGaps(t *testing.T) {
	thin := []byte(`{"openapi":"3.1.0","info":{"title":"t","version":"1"},
	  "tags":[{"name":"a","description":"A"}],
	  "paths":{"/x":{"post":{"tags":["b"],
	    "parameters":[{"name":"q","in":"query","schema":{"type":"string"}}],
	    "requestBody":{"content":{"application/json":{"schema":{"type":"object","properties":{"f":{"type":"string"}}}}}},
	    "responses":{"200":{"description":"ok","content":{"application/json":{"schema":{"type":"object"}}}},"400":{}}}}}}`)
	got := strings.Join(openAPICompletenessProblems(thin), "\n")
	for _, want := range []string{
		"info: missing description",
		"POST /x (): missing operationId",
		"POST /x (): missing summary",
		"POST /x (): missing description",
		`POST /x (): tag "b" is not declared`,
		`parameter "q" (in query): missing description`,
		`parameter "q" (in query): missing example`,
		"requestBody application/json: missing example",
		`property "f" missing description`,
		"response 400: missing description",
		"no 2xx response with both a schema and an example",
	} {
		if !strings.Contains(got, want) {
			t.Errorf("checker did not report %q; got:\n%s", want, got)
		}
	}
}

// TestOpenAPISpecIsComplete is this package's completeness gate over the
// embedded openapi.json.
func TestOpenAPISpecIsComplete(t *testing.T) {
	reportOpenAPIProblems(t, openAPICompletenessProblems(openAPISpec))
}
