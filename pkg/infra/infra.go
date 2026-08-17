// Package infra drives the Terraform roots of lerian-terraform-foundation: it
// resolves what to run, refuses to run it against the wrong AWS account, and walks
// the roots in dependency order.
//
// It is the Go port of this repository's deploy.sh. It does NOT replace that
// script yet: deploy.sh stays the supported path until the CLI has been exercised
// against real AWS, and only then does the script go away.
//
// It exists as a package rather than a program because two faces need it:
// cmd/lerian-infra, which is the terminal face, and the wizard
// (github.com/LerianStudio/lerian-wizzard), which imports this package as a
// library — not as a subprocess — so that a run cannot behave differently
// depending on which face started it. That is why it lives under pkg/ rather than
// internal/: internal/ does not cross a module boundary.
//
// Everything operator-facing therefore travels through the Progress interface
// instead of being printed here, and nothing in this package imports anything of
// the wizard's — the wizard adapts to infra, not the reverse.
//
// The layout it drives:
//
//	examples/aws/bootstrap                       state bucket + lock table
//	examples/aws/infra-base/{vpc,eks}            network and cluster
//	examples/aws/products/<product>/<service>    one Terraform root, one state
//
// Products and services are discovered from the filesystem. A new product works
// the moment its directory exists; there is no list to edit.
package infra

import (
	"fmt"
	"path/filepath"
	"strings"
)

// stateKeyPrefix namespaces the state keys by cloud. State keys are derived from
// the directory and never hardcoded, so a moved stack gets a new key by
// construction instead of by somebody remembering to change one.
const stateKeyPrefix = "aws"

// Action is what a run does to the roots it resolved.
type Action string

const (
	// ActionPlan plans every root and changes nothing.
	ActionPlan Action = "plan"
	// ActionApply plans, shows the summary, takes one confirmation, then applies the
	// saved plan files.
	ActionApply Action = "apply"
	// ActionDestroy is ActionApply over -destroy plans, in reverse dependency order.
	ActionDestroy Action = "destroy"
	// ActionOutput reads terraform output from every root.
	ActionOutput Action = "output"
	// ActionHelmValues merges the helm_values output of every root of a product into
	// one document.
	ActionHelmValues Action = "helm-values"
)

// ParseAction validates an operator-supplied action.
func ParseAction(value string) (Action, error) {
	switch Action(value) {
	case ActionPlan, ActionApply, ActionDestroy, ActionOutput, ActionHelmValues:
		return Action(value), nil
	default:
		return "", fmt.Errorf("infra: invalid action %q, want one of: plan, apply, destroy, output, helm-values", value)
	}
}

// Environments are the only environment names the repository supports:
// envs/<env>.tfvars, backend/<env>.hcl and the bootstrap workspace all key off
// exactly these, and every stack's own "environment" variable validates against
// the same list.
var Environments = []string{"dev", "stg", "prd"}

// ValidEnvironment reports whether name is one of Environments.
func ValidEnvironment(name string) bool {
	for _, env := range Environments {
		if env == name {
			return true
		}
	}
	return false
}

// Layout locates the parts of a lerian-terraform-foundation checkout. Every path
// in this package is absolute and derived from Root, so the caller's working
// directory never matters.
type Layout struct {
	// Root is the repository root: the directory holding examples/.
	Root string
}

// NewLayout returns the layout of the checkout at root, which must contain the
// examples/aws directory this package drives.
func NewLayout(root string) (Layout, error) {
	absolute, err := filepath.Abs(root)
	if err != nil {
		return Layout{}, fmt.Errorf("infra: cannot resolve %q: %w", root, err)
	}
	return Layout{Root: absolute}, nil
}

// AWSDir is examples/aws, the root of the v2 layout.
func (l Layout) AWSDir() string { return filepath.Join(l.Root, "examples", "aws") }

// ProductsDir holds one directory per product, each holding one directory per
// service.
func (l Layout) ProductsDir() string { return filepath.Join(l.AWSDir(), "products") }

// BackendDir holds backend/<env>.hcl, written by the bootstrap stack.
func (l Layout) BackendDir() string { return filepath.Join(l.AWSDir(), "backend") }

// BackendFile is the backend configuration of one environment.
func (l Layout) BackendFile(env string) string {
	return filepath.Join(l.BackendDir(), env+".hcl")
}

// ConfigFile is environments.conf, the environment-to-account mapping. It is
// gitignored because it carries account ids.
func (l Layout) ConfigFile() string { return filepath.Join(l.AWSDir(), "environments.conf") }

// ConfigExample is the committed template of ConfigFile.
func (l Layout) ConfigExample() string {
	return filepath.Join(l.AWSDir(), "environments.conf.example")
}

// BootstrapDir creates the state backend and therefore cannot use it.
func (l Layout) BootstrapDir() string { return filepath.Join(l.AWSDir(), "bootstrap") }

// VPCDir is the network every datastore resolves its subnets from.
func (l Layout) VPCDir() string { return filepath.Join(l.AWSDir(), "infra-base", "vpc") }

// EKSDir is the cluster the products are installed into.
func (l Layout) EKSDir() string { return filepath.Join(l.AWSDir(), "infra-base", "eks") }

// rel returns dir as a path relative to examples/aws, which is the identity of a
// unit: it names the stack, keys its state and labels it on screen.
func (l Layout) rel(dir string) string {
	relative, err := filepath.Rel(l.AWSDir(), dir)
	if err != nil {
		return dir
	}
	return filepath.ToSlash(relative)
}

// RepoRel returns dir relative to the repository root, which is what operator
// messages use so a copy-pasted path works from where the operator stands.
func (l Layout) RepoRel(path string) string {
	relative, err := filepath.Rel(l.Root, path)
	if err != nil {
		return path
	}
	return filepath.ToSlash(relative)
}

// Unit is one Terraform root: one directory, one state file, one lock.
type Unit struct {
	// Dir is the absolute path of the root.
	Dir string
	// Name identifies the unit everywhere it is seen: as the state key, as the row
	// in the plan table and as the step name in the wizard's checklist. It is the
	// directory relative to examples/aws, e.g. "products/midaz/postgres".
	Name string
	// Bootstrap marks the one root that runs on local state with a workspace per
	// environment, because it is the stack that creates the backend.
	Bootstrap bool
}

// StateKey is the S3 key of this unit's state, derived from the directory.
func (u Unit) StateKey() string {
	return stateKeyPrefix + "/" + u.Name + "/terraform.tfstate"
}

// slug is a filesystem-safe form of Name, used for the plan and log files of a run.
func (u Unit) slug() string { return strings.ReplaceAll(u.Name, "/", "-") }

// Stage is a group of units that may run in parallel with each other. Stages
// themselves always run in order: the units inside one have no dependency on each
// other — separate state, separate locks — but the stage after it depends on the
// stage before.
type Stage struct {
	Name  string
	Units []Unit
}

// Units flattens stages in order, which is what the preflight checks and the
// dry-run listing walk.
func Units(stages []Stage) []Unit {
	var units []Unit
	for _, stage := range stages {
		units = append(units, stage.Units...)
	}
	return units
}
