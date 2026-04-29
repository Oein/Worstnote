package sync

import "testing"

func TestJSONSemanticEqual(t *testing.T) {
	cases := []struct {
		name string
		a, b string
		want bool
	}{
		{"identical", `{"a":1}`, `{"a":1}`, true},
		{"key order", `{"a":1,"b":2}`, `{"b":2,"a":1}`, true},
		{"int vs float", `{"x":1}`, `{"x":1.0}`, true},
		{"trailing zeros", `{"x":0.10}`, `{"x":0.1}`, true},
		{"whitespace", `{"a":1,"b":2}`, `{"a": 1, "b": 2}`, true},
		{"nested reorder", `{"o":{"a":1,"b":2}}`, `{"o":{"b":2,"a":1}}`, true},
		{"array order matters", `[1,2,3]`, `[3,2,1]`, false},
		{"different value", `{"a":1}`, `{"a":2}`, false},
		{"different key", `{"a":1}`, `{"b":1}`, false},
		{"null vs missing", `{"a":1,"b":null}`, `{"a":1}`, false},
		{"empty", ``, `{}`, false},
		{"both empty", ``, ``, false},
		{"stroke realistic",
			`{"color":4286611584,"points":[[0.0,0.0],[1.5,2.0]],"width":0.7,"layerId":"x"}`,
			`{"layerId":"x","width":0.7,"points":[[0,0],[1.5,2.0]],"color":4286611584}`,
			true},
	}
	for _, c := range cases {
		got := jsonSemanticEqual([]byte(c.a), []byte(c.b))
		if got != c.want {
			t.Errorf("%s: jsonSemanticEqual(%q, %q) = %v, want %v",
				c.name, c.a, c.b, got, c.want)
		}
	}
}
