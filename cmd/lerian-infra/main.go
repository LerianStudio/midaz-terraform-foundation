// Command lerian-infra drives the Terraform roots of lerian-terraform-foundation
// from the command line. It is the terminal face of pkg/infra; the wizard is the
// other one, and both walk the same code, so a run cannot behave differently
// depending on which one started it.
//
// It is intended to replace this repository's deploy.sh and keeps its flags, but
// it has NOT replaced it yet: deploy.sh remains the supported path until the CLI
// has been exercised against real AWS.
package main

import (
	"bufio"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"text/tabwriter"

	"github.com/LerianStudio/lerian-terraform-foundation/pkg/infra"
)

// version is set at build time.
var version = "dev"

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := run(ctx, os.Args[1:], os.Stdout, os.Stderr); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			return
		}
		fmt.Fprintf(os.Stderr, "\nerror %v\n\n", err)
		os.Exit(1)
	}
}

type options struct {
	repo        string
	environment string
	target      string
	action      string
	format      string
	jobs        int
	autoApprove bool
	dryRun      bool
	list        bool
	showVersion bool
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	var opts options

	flags := flag.NewFlagSet("lerian-infra", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() { fmt.Fprint(stderr, usage) }

	flags.StringVar(&opts.repo, "repo", "",
		"path to the lerian-terraform-foundation checkout "+
			"(default: $LERIAN_TF_REPO, else discovered by walking up from the working directory)")
	flags.StringVar(&opts.environment, "env", "", "dev, stg or prd")
	flags.StringVar(&opts.target, "target", "infra-base", "what to operate on")
	flags.StringVar(&opts.action, "action", "plan", "plan, apply, destroy, output or helm-values")
	flags.StringVar(&opts.format, "format", "json", "json or yaml, for --action helm-values")
	flags.IntVar(&opts.jobs, "jobs", 4, "how many services of one product run at once")
	flags.BoolVar(&opts.autoApprove, "auto-approve", false, "skip the confirmation before apply/destroy")
	flags.BoolVar(&opts.dryRun, "dry-run", false, "resolve and print the execution plan, then exit")
	flags.BoolVar(&opts.list, "list", false, "list discoverable targets and exit")
	flags.BoolVar(&opts.showVersion, "version", false, "print the version and exit")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if rest := flags.Args(); len(rest) > 0 {
		return fmt.Errorf("unexpected argument %q\n"+
			"This command takes flags only. Run lerian-infra --help.", rest[0])
	}
	if opts.showVersion {
		fmt.Fprintf(stdout, "lerian-infra %s\n", version)
		return nil
	}

	layout, err := resolveLayout(opts.repo, os.Getenv("LERIAN_TF_REPO"))
	if err != nil {
		return err
	}

	catalog, err := infra.Discover(layout)
	if err != nil {
		return err
	}

	// --list makes no AWS call, reads no config and needs no tools.
	if opts.list {
		printTargets(stdout, layout, catalog)
		return nil
	}

	if !infra.ValidEnvironment(opts.environment) {
		if opts.environment == "" {
			return fmt.Errorf("--env is required\n"+
				"One of: %s.\n"+
				"It selects the AWS account (examples/aws/environments.conf), the state backend\n"+
				"(examples/aws/backend/<env>.hcl) and the variables file (envs/<env>.tfvars)\n"+
				"inside every stack.\n"+
				"  lerian-infra --env dev --target infra-base --action plan",
				strings.Join(infra.Environments, ", "))
		}
		return fmt.Errorf("invalid --env %q\n"+
			"Valid values: %s. These three are fixed: envs/<env>.tfvars, backend/<env>.hcl and\n"+
			"the bootstrap workspace all key off exactly these names.",
			opts.environment, strings.Join(infra.Environments, ", "))
	}

	action, err := infra.ParseAction(opts.action)
	if err != nil {
		return err
	}
	if opts.format != "json" && opts.format != "yaml" {
		return fmt.Errorf("invalid --format %q\nValid values: json, yaml.", opts.format)
	}
	if opts.jobs < 1 {
		return fmt.Errorf("invalid --jobs %d\nMust be at least 1. Default 4; use 1 to run sequentially.",
			opts.jobs)
	}
	if action == infra.ActionHelmValues {
		if err := requireProductTarget(opts.target); err != nil {
			return err
		}
	}

	// helm-values writes a document to stdout, so `> values.yaml` captures the
	// document and nothing else. Everything else goes to stderr in that mode.
	progressOut := stdout
	if action == infra.ActionHelmValues {
		progressOut = stderr
	}

	// Target resolution is pure filesystem work and reports the most common typo,
	// so it runs before the config is even opened: "unknown product 'ledger'" is a
	// more useful first error than "environments.conf is missing".
	stages, err := infra.Resolve(layout, catalog, opts.target)
	if err != nil {
		return err
	}

	config, err := infra.LoadEnvConfig(layout, opts.environment)
	if err != nil {
		return err
	}

	if action == infra.ActionDestroy {
		var warnings []infra.BackendWarning
		stages, warnings, err = infra.ForDestroy(stages, opts.target)
		if err != nil {
			return err
		}
		for _, warning := range warnings {
			fmt.Fprintf(stderr, "warn  %s\n", warning)
		}
	}

	allUnits := infra.Units(stages)
	if len(allUnits) == 0 {
		return fmt.Errorf("target %q resolved to no Terraform root\nRun lerian-infra --list.", opts.target)
	}

	backend, backendNote, err := loadBackend(layout, config, allUnits, opts.dryRun, stderr)
	if err != nil {
		return err
	}

	printPreflight(progressOut, layout, config, opts, backendNote)

	readiness := checkReadiness(progressOut, action, allUnits, opts.environment)

	// The terraform binary is verified before the dry run reports, not after: a dry
	// run that says "all ready" without a usable terraform has told the operator
	// the wrong thing. This runs the binary locally and makes no AWS call.
	terraform, err := infra.NewCLI(ctx)
	if err != nil {
		return err
	}
	terraform.Profile = config.Profile
	fmt.Fprintf(progressOut, "  terraform   %s\n", terraform.ExecPath())

	if opts.dryRun {
		return printDryRun(progressOut, stages, opts, backend, readiness)
	}

	if err := failOnUnready(readiness); err != nil {
		return err
	}

	caller, err := infra.VerifyAccount(ctx, infra.CLIIdentity{}, config)
	if err != nil {
		return err
	}
	fmt.Fprintf(progressOut, "\n  ok  account %s  (%s)\n", caller.Account, caller.ARN)

	runDir, err := os.MkdirTemp("", "lerian-infra-")
	if err != nil {
		return fmt.Errorf("cannot create the run directory: %w", err)
	}
	if err := os.Chmod(runDir, 0o700); err != nil {
		return fmt.Errorf("cannot restrict the run directory: %w", err)
	}
	// Saved plans can contain values read from state; the logs are kept so a
	// failure can be read after the run.
	defer removePlans(runDir)

	logs := infra.NewFileLogs(runDir)
	defer func() { _ = logs.Close() }()
	terraform.Logs = logs.Writer

	checklist := newChecklist(progressOut)
	runner, err := infra.NewRunner(infra.RunnerOptions{
		Layout:    layout,
		Env:       opts.environment,
		Backend:   backend,
		Terraform: terraform,
		Jobs:      opts.jobs,
		Progress:  checklist,
		RunDir:    runDir,
	})
	if err != nil {
		return err
	}

	switch action {
	case infra.ActionHelmValues:
		return writeHelmValues(ctx, runner, allUnits, opts.format, stdout)
	case infra.ActionOutput:
		return writeOutputs(ctx, runner, allUnits, stdout)
	default:
		return execute(ctx, runner, stages, action, opts, config, runDir, logs, progressOut)
	}
}

// repoMarkers are the directories a lerian-terraform-foundation checkout is
// recognised by. ALL of them must be present, and they are deliberately the two
// the tool itself depends on rather than a name that merely looks distinctive:
//
//	examples/aws/_modules   what every root's source = "../../../_modules/..."
//	                        resolves to, so its absence means the roots below it
//	                        cannot initialise at all;
//	examples/aws/backend    where LoadBackend reads <env>.hcl.
//
// Both are tracked in git — _modules holds the module sources, backend/ holds
// .gitkeep and README.md — so a fresh clone is recognised before Terraform has
// ever run in it. That is why the marker is not environments.conf or
// backend/<env>.hcl: both are gitignored, so a marker built on them would fail on
// exactly the checkout that has not been bootstrapped yet. It is not products/
// either: that is the directory being discovered, and a bare "products" is a
// common enough name to match something unrelated on the way up.
var repoMarkers = [][]string{
	{"examples", "aws", "_modules"},
	{"examples", "aws", "backend"},
}

// isRepoRoot reports whether dir is the root of a checkout on the AWS v2 layout.
func isRepoRoot(dir string) bool {
	for _, marker := range repoMarkers {
		info, err := os.Stat(filepath.Join(append([]string{dir}, marker...)...))
		if err != nil || !info.IsDir() {
			return false
		}
	}
	return true
}

// findRepoRoot walks up from dir looking for a checkout and returns "" when it
// reaches the filesystem root without finding one.
func findRepoRoot(dir string) string {
	for {
		if isRepoRoot(dir) {
			return dir
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return ""
		}
		dir = parent
	}
}

// resolveLayout finds the checkout to drive, in this order of precedence:
// an explicit --repo, then $LERIAN_TF_REPO, then a walk up from the working
// directory.
//
// The binary is built from the repository it drives, so the walk is the ordinary
// case and needs no flag: any directory inside the checkout resolves. The flag
// and the variable stay because `go install` puts the binary on $PATH, where it
// can be run from anywhere.
func resolveLayout(flagRepo, envRepo string) (infra.Layout, error) {
	root, source := flagRepo, "--repo"
	if root == "" {
		root, source = envRepo, "$LERIAN_TF_REPO"
	}
	if root == "" {
		working, err := os.Getwd()
		if err != nil {
			return infra.Layout{}, fmt.Errorf("cannot resolve the working directory: %w", err)
		}
		found := findRepoRoot(working)
		if found == "" {
			return infra.Layout{}, notACheckout(working, "the working directory and its parents")
		}
		root, source = found, "the working directory"
	}

	layout, err := infra.NewLayout(root)
	if err != nil {
		return infra.Layout{}, err
	}
	if !isRepoRoot(layout.Root) {
		return infra.Layout{}, notACheckout(layout.Root, source)
	}
	return layout, nil
}

// notACheckout is the single failure text for every way of not finding the
// repository, and it names all three ways of pointing at one — including the one
// the operator did not use, which is the whole reason this error exists.
func notACheckout(path, source string) error {
	return fmt.Errorf("no lerian-terraform-foundation checkout at %s (resolved from %s)\n"+
		"A checkout is recognised by the directories examples/aws/_modules and\n"+
		"examples/aws/backend; at least one of them is missing there.\n\n"+
		"Point lerian-infra at one. In order of precedence:\n"+
		"  1. lerian-infra --repo /path/to/lerian-terraform-foundation ...\n"+
		"  2. export LERIAN_TF_REPO=/path/to/lerian-terraform-foundation\n"+
		"  3. run it from inside the checkout — any directory in it will do, the root\n"+
		"     is found by walking up.",
		path, source)
}

// loadBackend reads backend/<env>.hcl and runs the two offline guards. A run made
// entirely of bootstrap does not need it: bootstrap is the stack that writes it.
func loadBackend(
	layout infra.Layout,
	config infra.EnvConfig,
	units []infra.Unit,
	dryRun bool,
	stderr io.Writer,
) (infra.Backend, string, error) {
	needed := false
	for _, unit := range units {
		if !unit.Bootstrap {
			needed = true
			break
		}
	}
	if !needed {
		return infra.Backend{}, "(not needed — bootstrap creates it)", nil
	}

	backend, err := infra.LoadBackend(layout, config.Environment)
	if err != nil {
		// The point of a dry run is to see the whole picture, including what is not
		// ready yet, so a missing backend file is reported rather than fatal.
		if dryRun && errors.Is(err, infra.ErrNoBackendFile) {
			return infra.Backend{}, "MISSING — run --target bootstrap --action apply first", nil
		}
		return infra.Backend{}, "", err
	}

	warnings, err := infra.CheckBackend(layout, config, backend)
	if err != nil {
		return infra.Backend{}, "", err
	}
	for _, warning := range warnings {
		fmt.Fprintf(stderr, "warn  %s\n", warning)
	}
	return backend, backend.Bucket, nil
}

func checkReadiness(out io.Writer, action infra.Action, units []infra.Unit, env string) []infra.Readiness {
	if action == infra.ActionOutput || action == infra.ActionHelmValues {
		// Read-only actions never pass -var-file, so the variables file is irrelevant
		// to them, and demanding it would block reading the outputs of a stack
		// somebody else applied.
		fmt.Fprintf(out, "  tfvars      not required for --action %s\n", action)
		return nil
	}
	return infra.CheckReadiness(units, env)
}

func failOnUnready(readiness []infra.Readiness) error {
	var problems []string
	for _, entry := range readiness {
		if !entry.Ready() {
			problems = append(problems, fmt.Sprintf("  %s: %s\n    %s",
				entry.Unit.Name, entry.Problem, indent(entry.Remediation, "    ")))
		}
	}
	if len(problems) == 0 {
		return nil
	}
	return fmt.Errorf("%d stack(s) are not ready:\n%s\n\n"+
		"Run with --dry-run to see the whole list without stopping at the first one.",
		len(problems), strings.Join(problems, "\n"))
}

func requireProductTarget(target string) error {
	switch {
	case target == "bootstrap", target == "all",
		target == "infra-base", strings.HasPrefix(target, "infra-base/"):
		return fmt.Errorf("--action helm-values needs a product target\n"+
			"%q has no helm_values output; the Helm handoff lives in products/<product>/<service>.\n"+
			"  lerian-infra --env dev --target midaz --action helm-values", target)
	}
	return nil
}

func execute(
	ctx context.Context,
	runner *infra.Runner,
	stages []infra.Stage,
	action infra.Action,
	opts options,
	config infra.EnvConfig,
	runDir string,
	logs *infra.FileLogs,
	out io.Writer,
) error {
	confirm := func(stage infra.Stage, plans []infra.UnitResult) error {
		printPlanTable(out, plans)
		if opts.autoApprove {
			return nil
		}
		verb := "apply"
		if action == infra.ActionDestroy {
			verb = "DESTROY"
		}
		return confirmOnStdin(out, fmt.Sprintf("%s %d stack(s) of %q in %s (account %s)?",
			verb, len(stage.Units), stage.Name, config.Environment, config.AccountID))
	}
	if action == infra.ActionPlan {
		confirm = nil
	}

	results, err := runner.Execute(ctx, stages, action, confirm)

	// The table is printed for a plan run too: it is the whole point of one.
	if action == infra.ActionPlan {
		for _, result := range results {
			fmt.Fprintf(out, "\n==> %s\n", result.Stage.Name)
			printPlanTable(out, result.Plans)
		}
	}

	if err != nil {
		printFailureLogs(out, results, logs)
		fmt.Fprintf(out, "\n  logs %s\n", runDir)
		return err
	}

	fmt.Fprintf(out, "\n==> Done\n")
	for _, result := range results {
		fmt.Fprintf(out, "  ok  %s  %s\n", result.Stage.Name, action)
	}
	fmt.Fprintf(out, "\n  environment %s   account %s\n  logs %s\n\n",
		config.Environment, config.AccountID, runDir)
	if action == infra.ActionPlan {
		fmt.Fprint(out, "  Nothing was changed. Re-run with --action apply to execute this plan.\n\n")
	}
	return nil
}

func writeHelmValues(
	ctx context.Context,
	runner *infra.Runner,
	units []infra.Unit,
	format string,
	stdout io.Writer,
) error {
	document, err := runner.HelmValues(ctx, units)
	if err != nil {
		return err
	}

	var rendered []byte
	if format == "yaml" {
		rendered, err = document.YAML()
	} else {
		rendered, err = document.JSON()
	}
	if err != nil {
		return err
	}
	_, err = stdout.Write(rendered)
	return err
}

func writeOutputs(ctx context.Context, runner *infra.Runner, units []infra.Unit, stdout io.Writer) error {
	outputs, err := runner.Outputs(ctx, units)
	if err != nil {
		return err
	}
	for _, unit := range units {
		values := outputs[unit.Name]
		fmt.Fprintf(stdout, "\n==> %s\n", unit.Name)
		names := make([]string, 0, len(values))
		for name := range values {
			names = append(names, name)
		}
		sort.Strings(names)
		for _, name := range names {
			fmt.Fprintf(stdout, "  %s = %s\n", name, values[name])
		}
	}
	return nil
}

// confirmOnStdin asks once, and only accepts the whole word.
func confirmOnStdin(out io.Writer, prompt string) error {
	info, err := os.Stdin.Stat()
	if err != nil || info.Mode()&os.ModeCharDevice == 0 {
		return fmt.Errorf("this run needs a confirmation but stdin is not a terminal\n"+
			"Pending: %s\n\n"+
			"Re-run from a terminal, or pass --auto-approve. The plan above is what would be\n"+
			"applied: --auto-approve does not re-plan, it applies exactly the saved plan files\n"+
			"that produced that table.", prompt)
	}

	fmt.Fprintf(out, "%s [type yes to continue]: ", prompt)
	reader := bufio.NewReader(os.Stdin)
	answer, err := reader.ReadString('\n')
	if err != nil && !errors.Is(err, io.EOF) {
		return fmt.Errorf("cannot read the confirmation: %w", err)
	}
	if strings.TrimSpace(answer) != "yes" {
		return infra.ErrAborted
	}
	return nil
}

func printPlanTable(out io.Writer, plans []infra.UnitResult) {
	writer := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(writer, "STACK\tSTATUS\tCREATE\tUPDATE\tDELETE\tTIME")
	for _, plan := range plans {
		if plan.Err != nil {
			fmt.Fprintf(writer, "%s\tFAILED\t-\t-\t-\t%s\n", plan.Unit.Name, plan.Elapsed.Round(1e9))
			continue
		}
		fmt.Fprintf(writer, "%s\tok\t%d\t%d\t%d\t%s\n", plan.Unit.Name,
			plan.Changes.Create, plan.Changes.Update, plan.Changes.Delete, plan.Elapsed.Round(1e9))
	}
	_ = writer.Flush()
}

func printFailureLogs(out io.Writer, results []infra.StageResult, logs *infra.FileLogs) {
	for _, result := range results {
		for _, phase := range [][]infra.UnitResult{result.Plans, result.Applies} {
			for _, unit := range phase {
				if unit.Err == nil {
					continue
				}
				fmt.Fprintf(out, "\n---- %s failed ----\n%s\n  full log: %s\n",
					unit.Unit.Name, indent(unit.Err.Error(), "  "), logs.Path(unit.Unit))
			}
		}
	}
}

func printPreflight(out io.Writer, layout infra.Layout, config infra.EnvConfig, opts options, backend string) {
	fmt.Fprintf(out, "\n==> Preflight\n")
	fmt.Fprintf(out, "  repo        %s\n", layout.Root)
	fmt.Fprintf(out, "  environment %s\n", config.Environment)
	fmt.Fprintf(out, "  account     %s  (declared in %s)\n",
		config.AccountID, layout.RepoRel(layout.ConfigFile()))
	fmt.Fprintf(out, "  profile     %s\n", profileLabel(config.Profile))
	fmt.Fprintf(out, "  region      %s\n", config.Region)
	fmt.Fprintf(out, "  backend     %s\n", backend)
	fmt.Fprintf(out, "  target      %s\n", opts.target)
	fmt.Fprintf(out, "  action      %s\n", opts.action)
}

func printDryRun(
	out io.Writer,
	stages []infra.Stage,
	opts options,
	backend infra.Backend,
	readiness []infra.Readiness,
) error {
	problems := map[string]infra.Readiness{}
	for _, entry := range readiness {
		if !entry.Ready() {
			problems[entry.Unit.Name] = entry
		}
	}

	fmt.Fprintf(out, "\n==> Execution plan (dry run — no AWS call was made)\n")
	for i, stage := range stages {
		fmt.Fprintf(out, "\n  stage %d: %s\n", i+1, stage.Name)
		if len(stage.Units) > 1 && opts.jobs > 1 {
			fmt.Fprintf(out, "    (%d units, up to %d in parallel)\n", len(stage.Units), opts.jobs)
		}
		for _, unit := range stage.Units {
			if unit.Bootstrap {
				fmt.Fprintf(out, "      %-44s local state, workspace=%s\n",
					unit.Name, opts.environment)
			} else {
				fmt.Fprintf(out, "      %-44s %s\n", unit.Name, unit.StateKey())
			}
			if problem, ok := problems[unit.Name]; ok {
				fmt.Fprintf(out, "        NOT READY: %s\n", problem.Problem)
			}
		}
	}

	backendPath := backend.Path
	if backendPath == "" {
		backendPath = "<none: bootstrap only>"
	}
	fmt.Fprintf(out, "\n  backend-config  %s\n", backendPath)
	fmt.Fprintf(out, "  var-file        <stack>/envs/%s.tfvars\n", opts.environment)
	fmt.Fprintf(out, "  init flags      -reconfigure -input=false  (bootstrap: workspace select/new)\n\n")

	if len(problems) > 0 {
		return fmt.Errorf("%d of %d stack(s) are NOT READY — see the NOT READY lines above.\n"+
			"A missing envs/%s.tfvars is copied from the *.tfvars-example next to it; a\n"+
			"placeholder is a <...> token that still needs a real value.",
			len(problems), len(readiness), opts.environment)
	}
	fmt.Fprintf(out, "  ok  all %d stack(s) ready\n\n", len(readiness))
	return nil
}

func printTargets(out io.Writer, layout infra.Layout, catalog infra.Catalog) {
	fmt.Fprintf(out, "Discovered targets  (from %s/*/*/main.tf)\n\n",
		layout.RepoRel(layout.ProductsDir()))
	fmt.Fprint(out, "  bootstrap\n  infra-base            infra-base/vpc  infra-base/eks\n  all\n\nProducts\n")

	writer := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	for _, name := range catalog.Names {
		fmt.Fprintf(writer, "  %s\t%s\n", name, strings.Join(catalog.Products[name], " "))
	}
	_ = writer.Flush()
}

func removePlans(runDir string) {
	entries, err := os.ReadDir(runDir)
	if err != nil {
		return
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".tfplan") {
			_ = os.Remove(filepath.Join(runDir, entry.Name()))
		}
	}
}

func indent(text, prefix string) string {
	lines := strings.Split(text, "\n")
	for i := 1; i < len(lines); i++ {
		lines[i] = prefix + lines[i]
	}
	return strings.Join(lines, "\n")
}

func profileLabel(profile string) string {
	if profile == "" {
		return "<ambient credentials>"
	}
	return profile
}
