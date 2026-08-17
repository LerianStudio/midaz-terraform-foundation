package infra

import (
	"testing"

	tfjson "github.com/hashicorp/terraform-json"
)

// countChanges replaces the jq the shell version counted plans with. The rule it
// has to keep: an action counts once per resource that carries it, so a
// replacement shows up as both a delete and a create — which is exactly what the
// operator needs to see before confirming.
func TestCountChanges(t *testing.T) {
	change := func(actions ...tfjson.Action) *tfjson.ResourceChange {
		return &tfjson.ResourceChange{Change: &tfjson.Change{Actions: actions}}
	}

	tests := []struct {
		name string
		plan *tfjson.Plan
		want Changes
	}{
		{
			name: "nil plan",
			plan: nil,
			want: Changes{},
		},
		{
			name: "no changes",
			plan: &tfjson.Plan{ResourceChanges: []*tfjson.ResourceChange{
				change(tfjson.ActionNoop),
			}},
			want: Changes{},
		},
		{
			name: "one of each",
			plan: &tfjson.Plan{ResourceChanges: []*tfjson.ResourceChange{
				change(tfjson.ActionCreate),
				change(tfjson.ActionUpdate),
				change(tfjson.ActionDelete),
			}},
			want: Changes{Create: 1, Update: 1, Delete: 1},
		},
		{
			name: "a replacement counts in both columns",
			plan: &tfjson.Plan{ResourceChanges: []*tfjson.ResourceChange{
				change(tfjson.ActionDelete, tfjson.ActionCreate),
			}},
			want: Changes{Create: 1, Delete: 1},
		},
		{
			name: "a resource with no change block is skipped",
			plan: &tfjson.Plan{ResourceChanges: []*tfjson.ResourceChange{
				{Address: "aws_db_instance.this"},
				nil,
				change(tfjson.ActionCreate),
			}},
			want: Changes{Create: 1},
		},
		{
			name: "reading is not a change",
			plan: &tfjson.Plan{ResourceChanges: []*tfjson.ResourceChange{
				change(tfjson.ActionRead),
			}},
			want: Changes{},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := countChanges(test.plan)
			if got != test.want {
				t.Errorf("countChanges = %+v, want %+v", got, test.want)
			}
			if got.Empty() != (test.want == Changes{}) {
				t.Errorf("Empty() = %v for %+v", got.Empty(), got)
			}
		})
	}
}
