package infra

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"sync"

	goversion "github.com/hashicorp/go-version"
	"github.com/hashicorp/terraform-exec/tfexec"
	tfjson "github.com/hashicorp/terraform-json"
)

// MinTerraformVersion is the oldest Terraform the repository's roots accept. It is
// the highest required_version any of them declares, so a binary below it fails on
// some stacks and not others — which is a worse way to find out than this one.
const MinTerraformVersion = "1.10.0"

// CLI is the Terraform implementation backed by the real binary, driven through
// hashicorp/terraform-exec rather than by assembling command lines.
//
// What that buys over shelling out: the plan comes back as a parsed
// terraform-json document instead of being counted with jq, outputs come back as
// typed JSON, and a failure is an error value rather than an exit code plus a log
// file to grep.
type CLI struct {
	execPath string

	// Logs says where the raw Terraform output of one unit goes. It is called from
	// several goroutines at once, one per unit in flight, so an implementation that
	// shares a writer must serialise it. A nil Logs discards the output, which is
	// what a caller that only wants the plan counts wants.
	Logs func(unit Unit) io.Writer

	// Profile is exported as AWS_PROFILE for every Terraform process. Empty leaves
	// the ambient credentials alone, which is the CI shape.
	Profile string

	mu       sync.Mutex
	byDir    map[string]*tfexec.Terraform
	envCache map[string]string
}

// NewCLI locates the terraform binary and verifies it is new enough.
//
// It is checked once, here, rather than being discovered as a cryptic failure
// inside the third stack of a run.
func NewCLI(ctx context.Context) (*CLI, error) {
	execPath, err := exec.LookPath("terraform")
	if err != nil {
		return nil, fmt.Errorf("infra: terraform not found in PATH\n" +
			"Install it: https://developer.hashicorp.com/terraform/install\n" +
			"This tool drives the Terraform CLI; it does not embed it.")
	}

	cli := &CLI{execPath: execPath, byDir: map[string]*tfexec.Terraform{}}

	// Version detection needs a working directory and any directory will do: the
	// version of the binary does not depend on what it is pointed at.
	probe, err := tfexec.NewTerraform(os.TempDir(), execPath)
	if err != nil {
		return nil, fmt.Errorf("infra: cannot run %s: %w", execPath, err)
	}
	current, _, err := probe.Version(ctx, false)
	if err != nil {
		return nil, fmt.Errorf("infra: cannot read the version of %s: %w", execPath, err)
	}
	minimum, err := goversion.NewVersion(MinTerraformVersion)
	if err != nil {
		return nil, fmt.Errorf("infra: bad MinTerraformVersion %q: %w", MinTerraformVersion, err)
	}
	if current.LessThan(minimum) {
		return nil, fmt.Errorf("infra: terraform %s is too old\n"+
			"The roots of this repository declare required_version >= %s, so a run would\n"+
			"succeed on some stacks and fail on others.\n"+
			"  binary : %s\n"+
			"Upgrade it, or put a newer one earlier in PATH.",
			current.String(), MinTerraformVersion, execPath)
	}
	return cli, nil
}

// ExecPath is the terraform binary this CLI drives, for the preflight summary.
func (c *CLI) ExecPath() string { return c.execPath }

// terraform returns the cached client for one root, creating it on first use.
func (c *CLI) terraform(unit Unit) (*tfexec.Terraform, error) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if client, ok := c.byDir[unit.Dir]; ok {
		return client, nil
	}

	client, err := tfexec.NewTerraform(unit.Dir, c.execPath)
	if err != nil {
		return nil, fmt.Errorf("infra: cannot prepare terraform for %s: %w", unit.Name, err)
	}

	if c.envCache == nil {
		// tfexec refuses to set the variables it controls itself (TF_INPUT, TF_LOG,
		// TF_WORKSPACE and friends), and CleanEnv drops exactly those. Passing the
		// rest through matters: PATH, HOME and the whole AWS_* family live there.
		environment := map[string]string{}
		for _, entry := range os.Environ() {
			for i := 0; i < len(entry); i++ {
				if entry[i] == '=' {
					environment[entry[:i]] = entry[i+1:]
					break
				}
			}
		}
		c.envCache = tfexec.CleanEnv(environment)
		if c.Profile != "" {
			c.envCache["AWS_PROFILE"] = c.Profile
		}
	}
	if err := client.SetEnv(c.envCache); err != nil {
		return nil, fmt.Errorf("infra: cannot set the environment for %s: %w", unit.Name, err)
	}

	if c.Logs != nil {
		if writer := c.Logs(unit); writer != nil {
			client.SetStdout(writer)
			client.SetStderr(writer)
		}
	}

	c.byDir[unit.Dir] = client
	return client, nil
}

// Init initialises one root.
//
// -reconfigure is passed on every non-bootstrap init and that is not a
// preference. .terraform/ caches the resolved backend, including the bucket of
// whichever environment was initialised in this checkout last. Without it,
// switching environments keeps the stale bucket and the run dies with a 403 at
// apply time — long after the plan looked healthy, and with an error that says
// nothing about the cause.
func (c *CLI) Init(ctx context.Context, unit Unit, opts InitOptions) error {
	client, err := c.terraform(unit)
	if err != nil {
		return err
	}

	if opts.BackendFile == "" {
		// bootstrap: local state, one workspace per environment.
		if err := client.Init(ctx); err != nil {
			return fmt.Errorf("infra: terraform init failed for %s: %w", unit.Name, err)
		}
	} else {
		if err := client.Init(ctx,
			tfexec.Reconfigure(true),
			tfexec.BackendConfig(opts.BackendFile),
			tfexec.BackendConfig("key="+opts.StateKey),
		); err != nil {
			return fmt.Errorf("infra: terraform init failed for %s: %w", unit.Name, err)
		}
	}

	if opts.Workspace == "" {
		return nil
	}
	// The bootstrap stack's own precondition asserts terraform.workspace ==
	// var.environment, so the workspace is selected before anything else runs.
	if err := client.WorkspaceSelect(ctx, opts.Workspace); err != nil {
		if err := client.WorkspaceNew(ctx, opts.Workspace); err != nil {
			return fmt.Errorf("infra: cannot select or create workspace %q in %s: %w",
				opts.Workspace, unit.Name, err)
		}
	}
	return nil
}

// Plan writes a saved plan and reports whether it holds any change.
func (c *CLI) Plan(ctx context.Context, unit Unit, opts PlanOptions) (bool, error) {
	client, err := c.terraform(unit)
	if err != nil {
		return false, err
	}

	options := []tfexec.PlanOption{tfexec.Out(opts.Out)}
	if opts.VarFile != "" {
		options = append(options, tfexec.VarFile(opts.VarFile))
	}
	if opts.Destroy {
		options = append(options, tfexec.Destroy(true))
	}

	changes, err := client.Plan(ctx, options...)
	if err != nil {
		return false, fmt.Errorf("infra: terraform plan failed for %s: %w", unit.Name, err)
	}
	return changes, nil
}

// ShowPlan counts what a saved plan would do.
func (c *CLI) ShowPlan(ctx context.Context, unit Unit, planFile string) (Changes, error) {
	client, err := c.terraform(unit)
	if err != nil {
		return Changes{}, err
	}
	plan, err := client.ShowPlanFile(ctx, planFile)
	if err != nil {
		return Changes{}, fmt.Errorf("infra: cannot read the saved plan of %s: %w", unit.Name, err)
	}
	return countChanges(plan), nil
}

// countChanges follows the same rule the shell version's jq did: an action counts
// once per resource that carries it, so a replacement — delete then create — shows
// up in both columns, which is exactly what the operator needs to see.
func countChanges(plan *tfjson.Plan) Changes {
	var changes Changes
	if plan == nil {
		return changes
	}
	for _, resource := range plan.ResourceChanges {
		if resource == nil || resource.Change == nil {
			continue
		}
		for _, action := range resource.Change.Actions {
			switch action {
			case tfjson.ActionCreate:
				changes.Create++
			case tfjson.ActionUpdate:
				changes.Update++
			case tfjson.ActionDelete:
				changes.Delete++
			}
		}
	}
	return changes
}

// Apply applies a saved plan file and never re-plans, so what runs is what the
// operator was shown and confirmed.
func (c *CLI) Apply(ctx context.Context, unit Unit, planFile string) error {
	client, err := c.terraform(unit)
	if err != nil {
		return err
	}
	if err := client.Apply(ctx, tfexec.DirOrPlan(planFile)); err != nil {
		return fmt.Errorf("infra: terraform apply failed for %s: %w", unit.Name, err)
	}
	return nil
}

// Output reads every output of a root.
func (c *CLI) Output(ctx context.Context, unit Unit) (map[string]json.RawMessage, error) {
	client, err := c.terraform(unit)
	if err != nil {
		return nil, err
	}
	outputs, err := client.Output(ctx)
	if err != nil {
		return nil, fmt.Errorf("infra: terraform output failed for %s: %w", unit.Name, err)
	}
	values := make(map[string]json.RawMessage, len(outputs))
	for name, meta := range outputs {
		values[name] = meta.Value
	}
	return values, nil
}
