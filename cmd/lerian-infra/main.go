// Command lerian-infra drives the Terraform roots of lerian-terraform-foundation
// from the command line. It is the terminal face of pkg/infra; the wizard is the
// other one, and both walk the same code, so a run cannot behave differently
// depending on which one started it.
//
// It replaced this repository's deploy.sh, whose flags it kept so that anything
// written against the script keeps working. GCP and Azure are not here: they are
// still on the pre-v2 layout, and deploy-legacy.sh is the only thing that reaches
// them.
package main

import (
	"bufio"
	"context"
	"encoding/json"
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
	"time"

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
	repo string
	// templatesDir relocates the managed checkout. A read-only home, a network
	// home, or an operator who keeps tooling under XDG all need it somewhere else.
	templatesDir string
	environment  string
	target       string
	action       string
	format       string
	jobs         int
	autoApprove  bool
	dryRun       bool
	list         bool
	showVersion  bool
}

func run(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	// One subcommand, dispatched before the flag set sees anything. Everything else
	// stays flags-only, so the surface deploy.sh defined is untouched.
	if len(args) > 0 && !strings.HasPrefix(args[0], "-") && args[0] == "init" {
		return runInit(ctx, args[1:], stdout, stderr)
	}

	var opts options

	flags := flag.NewFlagSet("lerian-infra", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() { fmt.Fprint(stderr, usage) }

	flags.StringVar(&opts.templatesDir, "templates-dir", "",
		"where the managed checkout lives (default ~/lerian/lerian-terraform-foundation)")
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
		// deploy.sh took the provider as a positional argument and redirected
		// azure/gcp to the legacy script. This tool replaces deploy.sh, so it
		// inherits that signpost: examples/gcp and examples/azure are still on
		// the pre-v2 flat layout (no environments, no per-service state) and
		// deploy-legacy.sh remains the only way to reach them.
		switch rest[0] {
		case "azure", "gcp":
			return fmt.Errorf("%q is not handled by this tool\n"+
				"lerian-infra is AWS-only: it assumes the v2 layout (one state per\n"+
				"service, environments, backend/<env>.hcl). The GCP and Azure examples\n"+
				"are still on the pre-v2 flat layout and kept their interactive flow:\n\n"+
				"  ./deploy-legacy.sh", rest[0])
		case "aws":
			return fmt.Errorf("this tool does not take a provider as a positional argument\n" +
				"It is AWS-only, and AWS needs an environment:\n\n" +
				"  lerian-infra --env dev --target infra-base --action plan")
		}
		return fmt.Errorf("unexpected argument %q\n"+
			"This command takes flags only. Run lerian-infra --help.", rest[0])
	}
	if opts.showVersion {
		fmt.Fprintf(stdout, "lerian-infra %s\n", version)
		return nil
	}

	layout, source, err := resolveLayout(opts.repo, os.Getenv("LERIAN_TF_REPO"), opts.templatesDir)
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

	// The shared tier is opt-in per engine. Dropping the ones this environment never
	// configured is what lets "apply the shared tier" run as one parallel stage
	// instead of refusing because an engine nobody uses has no tfvars.
	var skippedShared []string
	stages, skippedShared = infra.SkipUnconfiguredShared(stages, opts.environment)
	if len(stages) == 0 {
		return fmt.Errorf("target %q resolved to no configured Terraform root\n"+
			"The shared tier is opt-in per engine: run `lerian-infra init --env %s "+
			"--targets shared-resources` to configure the ones you want.",
			opts.target, opts.environment)
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

	// The terraform binary is verified before anything is printed, not after: a
	// preflight block that lists a terraform path it has not resolved yet would
	// have to be interrupted to print it, and that is exactly what used to split
	// the block in half — the path landed below the explanation, and the account
	// line floated loose under it.
	terraform, err := infra.NewCLI(ctx)
	if err != nil {
		return err
	}
	terraform.Profile = config.Profile

	// Resolved once, here, before anything runs in parallel. Four terraform
	// processes starting together each refreshing the same SSO token is a race we
	// created by parallelising, and it surfaces as a credential error that looks
	// like a broken profile.
	if !opts.dryRun {
		credentials, err := infra.ResolveCredentials(ctx, config.Profile)
		if err != nil {
			return err
		}
		terraform.Credentials = credentials
	}

	// The account check is part of the preflight, so it is resolved here too and
	// printed as that block's last line. Skipped for a dry run, which makes no AWS
	// call by definition.
	var caller infra.Caller
	if !opts.dryRun {
		caller, err = infra.VerifyAccount(ctx, infra.CLIIdentity{}, config)
		if err != nil {
			return err
		}
	}

	printPreflight(progressOut, layout, config, opts,
		templatesLine(ctx, layout, source), backendNote, terraform.ExecPath(), caller)

	for _, name := range skippedShared {
		// Said out loud, not inferred from an absence: an engine silently missing
		// from a run is how somebody discovers later that it was never applied.
		fmt.Fprintf(progressOut, "  skipping    %s  (not configured for %s)\n", name, opts.environment)
	}

	readiness := checkReadiness(progressOut, action, allUnits, opts.environment)
	explainStages(progressOut, stages, action)

	if opts.dryRun {
		return printDryRun(progressOut, stages, opts, backend, readiness)
	}

	if err := failOnUnready(readiness); err != nil {
		return err
	}

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

	checklist := newChecklist(progressOut, stages)
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

// checkoutSource says which of the four ways of finding a checkout was the one
// that worked. It reaches the preflight, because with more than one possible tree
// "which one is this command reading" stops being obvious.
type checkoutSource string

const (
	sourceFlag      checkoutSource = "--repo"
	sourceEnv       checkoutSource = "$LERIAN_TF_REPO"
	sourceWorkingIn checkoutSource = "the working directory"
	sourceManaged   checkoutSource = "managed"
)

// resolveLayout finds the checkout to drive, in this order of precedence:
// an explicit --repo, then $LERIAN_TF_REPO, then a walk up from the working
// directory, and finally the managed checkout this tool creates.
//
// The binary is built from the repository it drives, so the walk is the ordinary
// case and needs no flag: any directory inside the checkout resolves. The flag
// and the variable stay because `go install` puts the binary on $PATH, where it
// can be run from anywhere.
//
// The managed checkout comes LAST on purpose. An operator working inside a
// development checkout must keep driving that one — resolving to the managed tree
// because it also happens to exist would silently run their command against
// different templates than the ones they are editing.
//
// Finding is not creating: only `init` may clone. An `--action apply` that
// downloaded a repository halfway through is a surprise, and the whole point of
// the version pin is that acquiring templates is a deliberate act.
func resolveLayout(flagRepo, envRepo, templatesDir string) (infra.Layout, checkoutSource, error) {
	root, source := flagRepo, sourceFlag
	if root == "" {
		root, source = envRepo, sourceEnv
	}
	if root == "" {
		working, err := os.Getwd()
		if err != nil {
			return infra.Layout{}, "", fmt.Errorf("cannot resolve the working directory: %w", err)
		}
		if found := infra.FindCheckout(working); found != "" {
			root, source = found, sourceWorkingIn
		}
	}
	if root == "" {
		managed, err := infra.ManagedCheckoutPath(templatesDir)
		if err != nil {
			return infra.Layout{}, "", err
		}
		if infra.IsCheckout(managed) {
			root, source = managed, sourceManaged
		}
	}
	if root == "" {
		working, _ := os.Getwd()
		managed, _ := infra.ManagedCheckoutPath(templatesDir)
		return infra.Layout{}, "", noCheckoutAnywhere(working, managed)
	}

	layout, err := infra.NewLayout(root)
	if err != nil {
		return infra.Layout{}, "", err
	}
	if !infra.IsCheckout(layout.Root) {
		return infra.Layout{}, "", notACheckout(layout.Root, string(source))
	}
	return layout, source, nil
}

// templatesLine describes which tree this command is reading and at which tag.
//
// It replaced a bare "repo <path>" once a second possible tree existed. When a plan
// comes out different from what was expected, "which templates did this actually
// read" is the first question, and it used to be unanswerable from the output.
//
// A checkout that is not on a tag reports "untagged" rather than a guess: claiming a
// version for a branch, or for a commit between tags, is exactly the false assurance
// the version pin exists to remove. Reading the tag costs one git call, and git may
// legitimately be absent — a checkout handed over by --repo works without it — so a
// failure there drops the tag instead of failing the run.
func templatesLine(ctx context.Context, layout infra.Layout, source checkoutSource) string {
	line := layout.Root
	if git, err := infra.NewGitCLI(); err == nil {
		state := infra.InspectCheckout(ctx, git, layout.Root, source == sourceManaged)
		ref := state.Ref
		if ref == "" {
			ref = "untagged"
		}
		line += " @ " + ref
	}
	return fmt.Sprintf("%s  (%s)", line, source)
}

// notACheckout is the failure for a path the operator NAMED that turns out not to
// hold a checkout. It names all four ways of pointing at one — including the ones
// they did not use, which is the whole reason this error exists.
func notACheckout(path, source string) error {
	return fmt.Errorf("no lerian-terraform-foundation checkout at %s (resolved from %s)\n"+
		"A checkout is recognised by the directories examples/aws/_modules and\n"+
		"examples/aws/backend; at least one of them is missing there.\n\n"+
		"%s", path, source, pointingOptions())
}

// errNoCheckoutAnywhere marks the ONE failure that cloning can fix: nothing was
// named and nothing was found. A path the operator named that turns out not to hold
// a checkout is a typo, and acquiring a second tree on top of it would bury the
// mistake instead of reporting it — so that failure deliberately does not wrap this.
var errNoCheckoutAnywhere = errors.New("no checkout found")

// noCheckoutAnywhere is the failure when nothing was named and nothing was found.
//
// It lists every place that was looked at WITH the value each one had, because
// "not found" without "here is where I looked" leaves the operator guessing which
// of four mechanisms they got wrong.
func noCheckoutAnywhere(working, managed string) error {
	return fmt.Errorf("%w: no lerian-terraform-foundation checkout found\n\n"+
		"Looked in, in order:\n"+
		"  --repo                             not given\n"+
		"  $LERIAN_TF_REPO                    %s\n"+
		"  the working directory and parents  %s\n"+
		"  the managed checkout               %s\n\n"+
		"%s", errNoCheckoutAnywhere, valueOrUnset(os.Getenv("LERIAN_TF_REPO")),
		working, managed, pointingOptions())
}

func valueOrUnset(value string) string {
	if value == "" {
		return "not set"
	}
	return value
}

// pointingOptions is the remedy shared by both failures, so the two cannot drift
// into naming different sets of options.
func pointingOptions() string {
	return "Point lerian-infra at one. In order of precedence:\n" +
		"  1. lerian-infra --repo /path/to/lerian-terraform-foundation ...\n" +
		"  2. export LERIAN_TF_REPO=/path/to/lerian-terraform-foundation\n" +
		"  3. run it from inside the checkout — any directory in it will do, the root\n" +
		"     is found by walking up.\n" +
		"  4. lerian-infra init --clone — clones the templates matching this binary\n" +
		"     into ~/lerian/lerian-terraform-foundation and uses that from then on."
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
	started := time.Now()

	confirm := func(stage infra.Stage, plans []infra.UnitResult) error {
		if opts.autoApprove {
			return nil
		}
		// No table here either: the tree printed each stack's counts as it planned.
		// The question carries the stage total, which is the number being agreed to.
		var create, update, destroy int
		for _, plan := range plans {
			create += plan.Changes.Create
			update += plan.Changes.Update
			destroy += plan.Changes.Delete
		}
		verb := "Apply"
		if action == infra.ActionDestroy {
			verb = "DESTROY"
		}
		// Three short lines rather than one long one. What is being changed, where
		// it lands, and the question — in that order, because the account is the
		// fact worth re-reading before typing yes, and it was previously trailing a
		// parenthesis at the end of a line already past column eighty.
		theme := newStyle(out)
		fmt.Fprintf(out, "  %s %s\n", theme.bold(verb), theme.bold(stage.Name))
		fmt.Fprintf(out, "    %s\n", changeSummary(create, update, destroy))
		fmt.Fprintf(out, "    %s · account %s\n\n", config.Environment, config.AccountID)

		return confirmOnStdin(out, "  type yes to continue: ")
	}
	if action == infra.ActionPlan {
		confirm = nil
	}

	results, err := runner.Execute(ctx, stages, action, confirm)

	// No per-stage table here. The tree above already reported every stack's
	// counts as it finished; repeating them in a one-row table per stage said the
	// same thing twice and buried the one number an operator actually acts on.
	for _, result := range results {
		if result.Blocked {
			fmt.Fprintf(out, "\n  [%s] not planned — needs %s applied first\n",
				result.Stage.Name, result.BlockedBy)
		}
	}

	if err != nil {
		printFailureLogs(out, results, logs)
		fmt.Fprintf(out, "\n  logs %s\n", runDir)

		// The detail was just printed, in full, next to the stack it belongs to.
		// Returning the wrapped error would make main print the same Terraform
		// output a second time — the operator scrolls past one copy to find the
		// other and neither says anything the first did not. Aborting is passed
		// through untouched: callers test for it, and it carries no detail to
		// duplicate.
		if errors.Is(err, infra.ErrAborted) {
			return err
		}
		return reported{summary: summarise(err)}
	}

	printClusterHandoff(ctx, out, runner, results, action, config)

	fmt.Fprintf(out, "\n%s\n", newStyle(out).bold(totalsLine(results, action, time.Since(started))))
	fmt.Fprintf(out, "  logs %s\n\n", runDir)

	if action == infra.ActionPlan {
		if infra.Blocked(results) {
			// Not an error, and the exit code says so. A first run cannot plan past
			// the first layer, because every layer resolves the one below it in AWS
			// and a plan sees only what AWS already has.
			fmt.Fprintf(out,
				"  Nothing was changed. The stages above the first are not planned yet: each one\n"+
					"  resolves resources the stage below creates, and a plan only sees what already\n"+
					"  exists in AWS.\n\n"+
					"  Apply builds them in order, planning each stage after the one below it is up:\n\n"+
					"    lerian-infra --env %s --target %s --action apply\n\n",
				config.Environment, opts.target)
			return nil
		}
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
		fmt.Fprintf(stdout, "\n%s\n", newStyle(stdout).bold("==> "+unit.Name))
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
	// A real isatty, not a character-device check: /dev/null is a character device
	// too, and a CI run redirecting stdin from it would be mistaken for a human.
	if !isTerminal(os.Stdin) {
		return fmt.Errorf("this run needs a confirmation but stdin is not a terminal\n"+
			"Pending: %s\n\n"+
			"Re-run from a terminal, or pass --auto-approve. The plan above is what would be\n"+
			"applied: --auto-approve does not re-plan, it applies exactly the saved plan files\n"+
			"that produced that table.", prompt)
	}

	// Only what is typed after the question counts as the answer. Stages here take
	// minutes, and anything pressed while waiting is still queued when the prompt
	// finally appears.
	drainStdin()

	fmt.Fprint(out, prompt)
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

// printPreflight writes the whole block at once. Every value it names is already
// resolved by the time it is called, which is what keeps it from being split.
func printPreflight(
	out io.Writer,
	layout infra.Layout,
	config infra.EnvConfig,
	opts options,
	templates, backend, terraformPath string,
	caller infra.Caller,
) {
	theme := newStyle(out)
	fmt.Fprintf(out, "\n%s\n", theme.bold("==> Preflight"))
	fmt.Fprintf(out, "  templates   %s\n", templates)
	fmt.Fprintf(out, "  environment %s\n", config.Environment)
	fmt.Fprintf(out, "  account     %s  (declared in %s)\n",
		config.AccountID, layout.RepoRel(layout.ConfigFile()))
	fmt.Fprintf(out, "  profile     %s\n", profileLabel(config.Profile))
	fmt.Fprintf(out, "  region      %s\n", config.Region)
	fmt.Fprintf(out, "  backend     %s\n", backend)
	fmt.Fprintf(out, "  target      %s\n", opts.target)
	fmt.Fprintf(out, "  action      %s\n", opts.action)
	fmt.Fprintf(out, "  terraform   %s\n", terraformPath)

	if caller.Account == "" {
		return
	}
	// The credentials really do reach the declared account. Printed as the block's
	// closing line rather than floating on its own, because it is the verification
	// of everything listed above it.
	fmt.Fprintf(out, "  verified    %s\n", caller.ARN)
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

	fmt.Fprintf(out, "\n%s\n", newStyle(out).bold("==> Execution plan (dry run — no AWS call was made)"))
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

	// An empty path has two very different causes, and saying "bootstrap only" for
	// both told a fresh checkout that it needed no backend when in fact its backend
	// file had not been generated yet.
	backendPath := backend.Path
	if backendPath == "" {
		backendPath = "<none: bootstrap only>"
		for _, stage := range stages {
			for _, unit := range stage.Units {
				if !unit.Bootstrap {
					backendPath = "MISSING — run --target bootstrap --action apply first"
					break
				}
			}
		}
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

// totalsLine is the one number an operator acts on, in Terraform's own vocabulary
// and in the tense of what happened.
//
// It sums the plan counts, not the apply counts, because applying a saved plan
// performs exactly what that plan described — and for a plan run there is nothing
// else to sum.
func totalsLine(results []infra.StageResult, action infra.Action, elapsed time.Duration) string {
	var create, update, destroy, stacks, blocked int
	for _, result := range results {
		if result.Blocked {
			blocked += len(result.Stage.Units)
			continue
		}
		for _, plan := range result.Plans {
			if plan.Err != nil {
				continue
			}
			stacks++
			create += plan.Changes.Create
			update += plan.Changes.Update
			destroy += plan.Changes.Delete
		}
	}

	verbs := []string{"to add", "to change", "to destroy"}
	if action != infra.ActionPlan {
		verbs = []string{"added", "changed", "destroyed"}
	}

	line := fmt.Sprintf("  %d %s, %d %s, %d %s across %d stack(s) in %s",
		create, verbs[0], update, verbs[1], destroy, verbs[2], stacks, roundDuration(elapsed))
	if blocked > 0 {
		line += fmt.Sprintf("\n  %d stack(s) not planned yet", blocked)
	}
	return line
}

// roundDuration keeps the total readable: seconds below a minute, whole minutes
// above it. A 41-minute run reported to the second is noise.
func roundDuration(d time.Duration) time.Duration {
	if d < time.Minute {
		return d.Round(time.Second)
	}
	return d.Round(time.Minute)
}

// changeSummary is the counts with the zeros left in, unlike the per-stack lines.
//
// A stack line is one of six being scanned, so the zeros are noise there. This
// line is read once, deliberately, before authorising a spend — and "0 to destroy"
// is exactly the reassurance an operator wants stated rather than inferred from
// its absence.
func changeSummary(create, update, destroy int) string {
	return fmt.Sprintf("%d to add, %d to change, %d to destroy", create, update, destroy)
}

// explainStages says, in one short paragraph per stage, what is about to be built
// and why it comes first.
//
// The operator running this is frequently meeting Terraform for the first time.
// "target bootstrap, action apply" describes the command, not the intent; without
// the intent there is no way to tell a step that is supposed to take fifteen
// minutes from one that has hung, or a resource worth its cost from one created by
// accident.
func explainStages(out io.Writer, stages []infra.Stage, action infra.Action) {
	if action != infra.ActionApply {
		return
	}
	notes := map[string]string{
		"bootstrap": "Terraform has to record what it created somewhere durable, and that " +
			"store has to exist before anything else. This creates the S3 bucket that holds " +
			"the state and the DynamoDB table that locks it so two people cannot apply at " +
			"once. It also writes backend/<env>.hcl, which every later command reads. " +
			"Runs once per environment, costs cents.",
		"infra-base/vpc": "The network everything else is placed into: subnets across three " +
			"availability zones, split into public, private and database tiers. Every " +
			"datastore later finds its subnets by the tags set here.",
		"infra-base/eks": "The Kubernetes cluster the products run on. The slowest step by " +
			"far — the control plane alone takes around fifteen minutes, then the nodes " +
			"join and the add-ons install.",
	}

	var lines []string
	for _, stage := range stages {
		if note, ok := notes[stage.Name]; ok {
			lines = append(lines, fmt.Sprintf("  %s\n%s\n", newStyle(out).bold(stage.Name), wrapIndent(note, "    ", 76)))
			continue
		}
		if stage.Name == "shared-resources" {
			lines = append(lines, fmt.Sprintf("  %s\n%s\n", newStyle(out).bold(stage.Name),
				wrapIndent("The datastores every product in shared mode will resolve. "+
					"They must exist before any product that points at them.", "    ", 76)))
			continue
		}
		lines = append(lines, fmt.Sprintf("  %s\n%s\n", newStyle(out).bold(stage.Name),
			wrapIndent(fmt.Sprintf("The datastores for %s. In dedicated mode they are created here; "+
				"in shared mode this creates nothing and resolves the shared tier instead.",
				stage.Name), "    ", 76)))
	}
	if len(lines) == 0 {
		return
	}
	fmt.Fprintf(out, "\n%s\n\n", newStyle(out).bold("==> What this will do"))
	for _, line := range lines {
		fmt.Fprint(out, line)
	}
}

// wrapIndent breaks text at width and indents every line, so a paragraph stays
// readable in an eighty-column terminal.
func wrapIndent(text, indent string, width int) string {
	words := strings.Fields(text)
	if len(words) == 0 {
		return ""
	}
	var out strings.Builder
	line := indent
	for _, word := range words {
		if len(line)+len(word)+1 > width && line != indent {
			out.WriteString(line + "\n")
			line = indent
		}
		if line != indent {
			line += " "
		}
		line += word
	}
	out.WriteString(line)
	return out.String()
}

// printClusterHandoff tells the operator how to reach the cluster that was just
// created.
//
// A finished EKS apply leaves a cluster nothing on the machine can talk to yet:
// kubectl reads ~/.kube/config, and Terraform does not write it. Ending the run
// with "57 added" and nothing else made the next step a search — for the right AWS
// CLI verb, the cluster's exact name, and which profile it lives under, all of
// which this run already knows.
//
// The name is read from the stack's own output rather than derived from the naming
// contract, so a cluster whose name was overridden is still reported correctly.
func printClusterHandoff(
	ctx context.Context,
	out io.Writer,
	runner *infra.Runner,
	results []infra.StageResult,
	action infra.Action,
	config infra.EnvConfig,
) {
	if action != infra.ActionApply {
		return
	}

	var eks *infra.Unit
	for _, result := range results {
		if result.Blocked || len(result.Applies) == 0 {
			continue
		}
		for i, applied := range result.Applies {
			if applied.Err == nil && applied.Unit.Name == "infra-base/eks" {
				eks = &result.Applies[i].Unit
			}
		}
	}
	if eks == nil {
		return
	}

	outputs, err := runner.Outputs(ctx, []infra.Unit{*eks})
	if err != nil {
		// Not worth failing a successful apply over: the cluster is up either way,
		// and the operator can read the name from the console.
		return
	}
	name := ""
	if raw, ok := outputs[eks.Name]["cluster_name"]; ok {
		_ = json.Unmarshal(raw, &name)
	}
	if name == "" {
		return
	}

	profile := ""
	if config.Profile != "" {
		profile = " --profile " + config.Profile
	}

	theme := newStyle(out)
	fmt.Fprintf(out, "\n%s\n\n", theme.bold("==> Reaching the cluster"))
	fmt.Fprint(out, wrapIndent(
		"The cluster is up, but nothing on this machine can talk to it yet: kubectl "+
			"reads ~/.kube/config and Terraform does not write it. This adds the "+
			"context and makes it current:", "  ", 78)+"\n\n")
	fmt.Fprintf(out, "    aws eks update-kubeconfig --name %s --region %s%s\n\n",
		name, config.Region, profile)
	fmt.Fprint(out, wrapIndent("Then confirm the nodes have joined:", "  ", 78)+"\n\n")
	fmt.Fprintf(out, "    kubectl get nodes\n\n")
	fmt.Fprint(out, wrapIndent(
		"An empty list right after the apply is normal for a minute or two while the "+
			"nodes register.", "  ", 78)+"\n\n")

	// The likeliest reason kubectl hangs, and the one whose symptom explains
	// nothing: a timeout, not a refusal. Only the allow-listed address reaches the
	// API at all, and a home connection changes address often enough that the
	// address answered during init is frequently already stale.
	fmt.Fprint(out, wrapIndent(
		"If it times out instead — no error, just a hang — the API is refusing your "+
			"current address. Only "+strings.Join(allowedCIDRs(outputs[eks.Name]), ", ")+
			" can reach it. Compare it with:", "  ", 78)+"\n\n")
	fmt.Fprintf(out, "    curl -s https://checkip.amazonaws.com\n\n")
	fmt.Fprint(out, wrapIndent(
		"and if it moved, update allowed_api_access_cidrs in "+
			"examples/aws/infra-base/eks/envs/"+config.Environment+".tfvars and re-apply "+
			"infra-base/eks. A changed egress address is the usual cause, not a broken "+
			"cluster.", "  ", 78)+"\n")
}

// allowedCIDRs reads the API allow-list the cluster was applied with, so the
// handoff can name the actual address instead of describing the concept.
func allowedCIDRs(outputs map[string]json.RawMessage) []string {
	raw, ok := outputs["allowed_api_access_cidrs"]
	if !ok {
		return []string{"the address allowed at apply time"}
	}
	var cidrs []string
	if err := json.Unmarshal(raw, &cidrs); err != nil || len(cidrs) == 0 {
		return []string{"the address allowed at apply time"}
	}
	return cidrs
}

// reported is an error whose detail has already been shown to the operator.
//
// main prints what it is given, so an error that has been reported in place has to
// arrive short or it arrives twice.
type reported struct{ summary string }

func (r reported) Error() string { return r.summary }

// summarise keeps the first line of a Terraform failure, which names what broke,
// and drops the body that was already printed above.
func summarise(err error) string {
	line := firstLine(err.Error())
	// The wrapped chain ends in the raw terraform output; the part before the last
	// colon is this package's own explanation, which is the useful half.
	if index := strings.LastIndex(line, ": "); index > 0 && index < len(line)-2 {
		return line
	}
	return line
}
