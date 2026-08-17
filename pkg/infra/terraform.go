package infra

import (
	"context"
	"encoding/json"
)

// InitOptions configures `terraform init` for one root.
type InitOptions struct {
	// BackendFile is examples/aws/backend/<env>.hcl. Empty means the root keeps
	// local state, which only bootstrap does — it is the stack that creates the
	// backend, so it cannot use it.
	BackendFile string
	// StateKey is the object key inside the state bucket, derived from the
	// directory. Ignored when BackendFile is empty.
	StateKey string
	// Workspace, when set, is selected after init and created if it does not exist.
	// Only bootstrap uses workspaces: its own precondition asserts
	// terraform.workspace == var.environment.
	Workspace string
}

// PlanOptions configures `terraform plan` for one root.
type PlanOptions struct {
	// VarFile is <root>/envs/<env>.tfvars.
	VarFile string
	// Out is where the plan is saved. What gets applied later is this file and
	// nothing else, so what runs is exactly what was shown.
	Out string
	// Destroy plans the teardown instead of the build.
	Destroy bool
}

// Changes is the create/update/delete count of a saved plan, which is the row the
// operator reads before confirming.
type Changes struct {
	Create int
	Update int
	Delete int
}

// Empty reports whether the plan would change nothing.
func (c Changes) Empty() bool { return c.Create == 0 && c.Update == 0 && c.Delete == 0 }

// Terraform is the Terraform CLI, narrowed to what this package needs.
//
// It is an interface so the ordering, the guards and the helm_values merge can be
// tested without Terraform, credentials or an AWS account — the shell version could
// only be tested by stubbing the binary and reading back the argv it recorded.
type Terraform interface {
	// Init initialises one root. Every call passes -reconfigure; see the note on
	// the implementation for why that is not optional.
	Init(ctx context.Context, unit Unit, opts InitOptions) error
	// Plan writes a saved plan and reports whether it contains changes.
	Plan(ctx context.Context, unit Unit, opts PlanOptions) (bool, error)
	// ShowPlan reads back the counts of a saved plan.
	ShowPlan(ctx context.Context, unit Unit, planFile string) (Changes, error)
	// Apply applies a saved plan file. It never re-plans.
	Apply(ctx context.Context, unit Unit, planFile string) error
	// Output reads every output of a root as raw JSON, so a caller that wants one
	// output does not pay for a second process.
	Output(ctx context.Context, unit Unit) (map[string]json.RawMessage, error)
}
