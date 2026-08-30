package main

// The init subcommand writes the configuration a fresh checkout needs before any
// Terraform can run: the environments.conf section for one environment, and the
// envs/<env>.tfvars of the roots that will be applied.
//
// Its shape follows one rule. Every decision is a flag; a terminal turns the
// missing flags into questions. Nothing can be decided by a prompt that cannot be
// decided by a flag, because the graphical front end drives the same functions and
// a capability that only exists behind a prompt is a capability it would not have.

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"sort"
	"strings"
	"text/tabwriter"
	"time"

	"github.com/LerianStudio/lerian-terraform-foundation/pkg/infra"
)

const initUsage = `lerian-infra init — write the configuration a fresh checkout needs

Usage:
  lerian-infra init --env dev [flags]

Writes examples/aws/environments.conf and the envs/<env>.tfvars of the roots you
name, from the committed *.tfvars-example next to each one. It touches no AWS
resource: it only asks STS who a profile is, and optionally looks up this
machine's egress address.

In a terminal, any flag you leave out is asked for. Outside one, a missing
decision is an error naming the flag, so a CI run never guesses.

Flags:
  --env <name>          dev, stg or prd. Required.
  --profile <name>      AWS profile. Empty means ambient credentials (CI, IRSA).
  --region <name>       AWS region for this environment.
  --account <id>        Expected 12-digit account. Verified against the profile.
  --targets <list>      Comma-separated roots to materialise tfvars for,
                        e.g. infra-base,midaz. Default: infra-base.
  --api-cidr <v>        'auto' to detect this machine's egress address, or an
                        explicit address for the EKS API allow-list.
  --mode <m>            dedicated (each product gets its own datastores) or
                        shared (they resolve the tier owned by
                        products/shared-resources). Applies to every datastore
                        of the target. Default: dedicated.
  --set <TOKEN>=<v>     Fill a template placeholder by name. Repeatable, and the
                        escape hatch for any token this build does not know.
  --force               Replace configuration that already exists and differs.
  --dry-run             Show what would be written, write nothing.
  --auto-approve        Skip the confirmation before writing. It does NOT authorise
                        a clone — see --clone.
  --repo <path>         The checkout to configure. Using it turns the clone off:
                        you are saying where the templates already are.

THE TEMPLATES
  This binary and the Terraform templates ship from ONE tag. The chart mapping
  compiled into the binary and the helm_values expressions in the HCL are two
  halves of one contract, so a checkout this command creates is pinned to the tag
  matching the binary, never to a branch.

  --clone               Clone the templates into the managed checkout, which lives
                        at ~/lerian/lerian-terraform-foundation. Not hidden, and
                        named after the repository, because it is an ordinary git
                        checkout you are meant to be able to open and use by hand.
  --no-clone            Fail instead of cloning when no checkout is found.
  --sync                Move the managed checkout to this binary's tag, then exit.
                        Your environments.conf and every envs/*.tfvars survive it:
                        they are gitignored, and a checkout does not touch
                        untracked or ignored files. That is why the path carries no
                        version — a versioned directory would orphan all of it on
                        every upgrade.
  --templates-dir <p>   Put the managed checkout somewhere else: a read-only home, a
                        network home, or tooling kept under XDG.

  In a terminal, a missing checkout is offered as a question. Outside one it is an
  error naming --clone and --no-clone, because a CI run must never download a
  repository by accident.

  LERIAN_TEMPLATES_REPO overrides where the clone comes from, for an air-gapped
  client with an internal mirror or an organisation that vendors the templates into
  its own git server.

Examples:
  lerian-infra init --env dev
  lerian-infra init --env dev --profile lerian-dev --region us-east-2 \
      --targets infra-base,midaz --api-cidr auto
`

type initOptions struct {
	repo string
	// templatesDir relocates the managed checkout, for a read-only home, a network
	// home, or an operator who keeps tooling under XDG.
	templatesDir string
	environment  string
	profile      string
	region       string
	account      string
	targets      string
	apiCIDR      string
	mode         string
	force        bool
	dryRun       bool
	autoApprove  bool
	// clone and noClone are the explicit decision about acquiring the templates.
	// Both set is an error rather than a silent precedence: an operator who typed
	// both does not know what they want, and picking one for them hides that.
	clone   bool
	noClone bool
	// sync moves an existing managed checkout to the tag matching this binary and
	// writes nothing else.
	sync bool
	set  tokenValues
}

// tokenValues collects repeated --set token=value pairs.
type tokenValues map[string]string

func (t tokenValues) String() string { return "" }

func (t tokenValues) Set(pair string) error {
	token, value, found := strings.Cut(pair, "=")
	token = strings.TrimSpace(token)
	if !found || token == "" {
		return fmt.Errorf("expected token=value, got %q", pair)
	}
	t[token] = value
	return nil
}

// runInit is the entry point for `lerian-infra init`.
func runInit(ctx context.Context, args []string, stdout, stderr io.Writer) error {
	var opts initOptions

	flags := flag.NewFlagSet("lerian-infra init", flag.ContinueOnError)
	flags.SetOutput(stderr)
	flags.Usage = func() { fmt.Fprint(stderr, initUsage) }

	flags.StringVar(&opts.repo, "repo", "", "path to the checkout")
	flags.StringVar(&opts.templatesDir, "templates-dir", "",
		"where the managed checkout lives (default ~/lerian/lerian-terraform-foundation)")
	flags.StringVar(&opts.environment, "env", "", "dev, stg or prd")
	flags.StringVar(&opts.profile, "profile", "", "AWS profile")
	flags.StringVar(&opts.region, "region", "", "AWS region")
	flags.StringVar(&opts.account, "account", "", "expected 12-digit account id")
	flags.StringVar(&opts.targets, "targets", "", "comma-separated roots, e.g. infra-base,midaz")
	flags.StringVar(&opts.apiCIDR, "api-cidr", "", "'auto' or an explicit address")
	flags.StringVar(&opts.mode, "mode", "", "dedicated or shared, for every datastore of the target")
	flags.BoolVar(&opts.force, "force", false, "replace existing configuration that differs")
	flags.BoolVar(&opts.dryRun, "dry-run", false, "show what would be written")
	flags.BoolVar(&opts.autoApprove, "auto-approve", false, "skip the confirmation")
	flags.BoolVar(&opts.clone, "clone", false,
		"clone the templates matching this binary into the managed checkout")
	flags.BoolVar(&opts.noClone, "no-clone", false,
		"fail instead of cloning when no checkout is found")
	flags.BoolVar(&opts.sync, "sync", false,
		"move the managed checkout to the tag matching this binary, then exit")
	opts.set = tokenValues{}
	flags.Var(opts.set, "set", "fill a template placeholder: --set '<TOKEN>=value' (repeatable)")

	if err := flags.Parse(args); err != nil {
		return err
	}
	if rest := flags.Args(); len(rest) > 0 {
		return fmt.Errorf("unexpected argument %q\nRun lerian-infra init --help.", rest[0])
	}

	if err := opts.validateTemplateFlags(); err != nil {
		return err
	}

	// A terminal is what separates "ask" from "fail": the same missing value is a
	// question here and an error in CI.
	ask := newPrompter(stdout)

	if opts.sync {
		return runSync(ctx, opts, stdout)
	}

	layout, source, err := resolveLayout(opts.repo, os.Getenv("LERIAN_TF_REPO"), opts.templatesDir)
	if err != nil {
		// Only a total absence is recoverable by cloning. A path the operator named
		// that turns out not to be a checkout is their typo, and downloading a second
		// tree on top of it would bury the mistake instead of reporting it.
		if !errors.Is(err, errNoCheckoutAnywhere) {
			return err
		}
		layout, err = acquireTemplates(ctx, opts, ask, stdout)
		if err != nil {
			return err
		}
		source = sourceManaged
	}
	warnVersionMismatch(ctx, stdout, layout, source)

	plan, err := buildInitPlan(ctx, layout, opts, ask)
	if err != nil {
		return err
	}

	printModeDisclaimer(stdout, plan)
	printInitPlan(stdout, layout, plan)
	printSharedTierNotice(stdout, plan)
	printUnshareableNotice(stdout, plan)
	if opts.dryRun {
		fmt.Fprintf(stdout, "\n  dry run — nothing was written\n\n")
		return nil
	}
	if !plan.hasWork() {
		fmt.Fprintf(stdout, "\n  nothing to do — the configuration already matches\n\n")
		return nil
	}
	if conflicts := plan.conflicts(layout); len(conflicts) > 0 {
		return fmt.Errorf("%d file(s) already exist with different content\n"+
			"Nothing was written. Review the differences above, then either edit those\n"+
			"files yourself or re-run with --force to replace them:\n  %s",
			len(conflicts), strings.Join(conflicts, "\n  "))
	}

	if !opts.autoApprove {
		if err := ask.confirm(stderr, fmt.Sprintf("Write %d file(s)?", len(plan.writes))); err != nil {
			return err
		}
	}
	return plan.commit(layout)
}

// initPlan is the whole decision, computed before anything is written, so the
// confirmation is about a concrete list of files rather than an intention.
type initPlan struct {
	env     infra.EnvSpec
	caller  infra.Caller
	units   []infra.Unit
	apiCIDR string
	mode    string
	// sharedUnits are the tier roots pulled in because the products point at them.
	sharedUnits []infra.Unit
	// modeless are chosen roots with no dedicated/shared switch, so shared mode
	// does not reach them. S3 is the case: a bucket is never shared, so those
	// roots still create one and the operator has to be told.
	modeless []infra.Unit
	writes   []plannedWrite
	forceSet bool
}

type plannedWrite struct {
	// apply performs the write for real; result is what the dry run predicted.
	apply  func(infra.Layout) (infra.WriteResult, error)
	result infra.WriteResult
	label  string
	// role says what this file is for, in the operator's terms.
	//
	// Without it the table listed a product's tfvars identically whether it was
	// about to create a database or merely look one up, and the reasonable reading
	// of four rows under products/midaz was "this will build four databases" — the
	// opposite of what shared mode does.
	role string
}

func (p initPlan) hasWork() bool {
	for _, write := range p.writes {
		if write.result.Action != infra.WriteUnchanged {
			return true
		}
	}
	return false
}

// conflicts lists the repository-relative paths that were not written, matching
// how the table above names them.
func (p initPlan) conflicts(layout infra.Layout) []string {
	var paths []string
	for _, write := range p.writes {
		if write.result.Action == infra.WriteConflict {
			paths = append(paths, layout.RepoRel(write.result.Path))
		}
	}
	return paths
}

func (p initPlan) commit(layout infra.Layout) error {
	for _, write := range p.writes {
		if write.result.Action == infra.WriteUnchanged {
			continue
		}
		if _, err := write.apply(layout); err != nil {
			return err
		}
	}
	return nil
}

// buildInitPlan resolves every decision, asking when it can and failing with the
// flag name when it cannot, then computes the writes as a dry run.
func buildInitPlan(
	ctx context.Context,
	layout infra.Layout,
	opts initOptions,
	ask *prompter,
) (initPlan, error) {
	var plan initPlan

	environment := strings.TrimSpace(opts.environment)
	if environment == "" {
		// Deliberately not defaulted outside a terminal. Every other value here has
		// a sane default; the environment decides which AWS account the account
		// guard will demand, and guessing it is how a run aimed at dev ends up
		// pointed somewhere else.
		if !ask.interactive {
			return plan, fmt.Errorf("--env is required\n"+
				"Valid values: %s.", strings.Join(infra.Environments, ", "))
		}
		answer, err := ask.ask(
			"Which environment are you setting up?",
			"Picks the AWS account, the state bucket and the sizing of every resource.",
			"dev", "--env")
		if err != nil {
			return plan, err
		}
		environment = answer
	}
	if !infra.ValidEnvironment(environment) {
		return plan, fmt.Errorf("invalid environment %q\n"+
			"Valid values: %s. These three are fixed: envs/<env>.tfvars, backend/<env>.hcl\n"+
			"and the bootstrap workspace all key off exactly these names.",
			environment, strings.Join(infra.Environments, ", "))
	}

	profile, region, caller, err := resolveCredentials(ctx, opts, ask)
	if err != nil {
		return plan, err
	}
	if opts.account != "" && caller.Account != "" && opts.account != caller.Account {
		return plan, fmt.Errorf("the profile does not reach the account you declared\n"+
			"  --account  %s\n  %-10s %s\n"+
			"One of the two is wrong. Writing this would produce a configuration whose own\n"+
			"account guard refuses every run.", opts.account, profileLabel(profile), caller.Account)
	}
	account := caller.Account
	if account == "" {
		account = opts.account
	}
	if account == "" {
		return plan, fmt.Errorf("no AWS account could be determined\n" +
			"Either give a profile that resolves (--profile) or state the account\n" +
			"explicitly (--account 123456789012).")
	}

	plan.caller = caller
	plan.env = infra.EnvSpec{
		Environment: environment,
		AccountID:   account,
		Profile:     profile,
		Region:      region,
	}

	// Targets decide which tfvars get written.
	targets := strings.TrimSpace(opts.targets)
	if targets == "" {
		answer, err := ask.ask(
			"What do you want to configure?",
			"infra-base is the VPC and the cluster. Add products to configure their "+
				"datastores too, e.g. infra-base,midaz",
			"infra-base", "--targets")
		if err != nil {
			return plan, err
		}
		targets = answer
	}
	catalog, err := infra.Discover(layout)
	if err != nil {
		return plan, err
	}
	stages, err := infra.Resolve(layout, catalog, targets)
	if err != nil {
		return plan, err
	}
	for _, stage := range stages {
		plan.units = append(plan.units, stage.Units...)
	}

	// bootstrap is always configured, even when it was not named as a target.
	//
	// It is the first command anybody runs and it needs a tfvars like every other
	// root. Leaving it out meant the golden path — init, then bootstrap — failed on
	// its second step, every time, with a "missing envs/dev.tfvars" that the tool
	// had just had the chance to prevent.
	if !targetsBootstrap(plan.units) {
		bootstrapStages, err := infra.Resolve(layout, catalog, "bootstrap")
		if err != nil {
			return plan, err
		}
		for _, stage := range bootstrapStages {
			for _, unit := range stage.Units {
				// Added on this tool's initiative, not asked for, so a bootstrap that
				// has no template for this environment is skipped rather than made
				// into an error about a target the operator never named.
				if _, err := os.Stat(infra.VarFile(unit, environment) + "-example"); err != nil {
					continue
				}
				plan.units = append(plan.units, unit)
			}
		}
	}

	// One mode for every datastore of the target: mixing dedicated and shared
	// within a product is not supported yet, so this is a single decision rather
	// than one per service.
	mode := strings.TrimSpace(opts.mode)
	if mode == "" && len(plan.units) > 0 {
		answer, err := ask.ask(
			"Should each product own its datastores, or share one set?",
			"dedicated = every product gets its own. shared = they all resolve one "+
				"tier you provision separately (cheaper from the third product on).",
			infra.DedicatedMode, "--mode")
		if err != nil {
			return plan, err
		}
		mode = answer
	}
	if mode != "" && !infra.ValidMode(mode) {
		return plan, fmt.Errorf("invalid --mode %q\nValid values: %s, %s.",
			mode, infra.DedicatedMode, infra.SharedMode)
	}
	plan.mode = mode

	// In shared mode the products resolve a tier they do not create, so configuring
	// them without configuring that tier leaves a checkout that cannot be applied.
	// The roots are added here; applying them is still an explicit, separate step,
	// because the shared tier is a blast radius the operator opts into knowingly.
	if plan.mode == infra.SharedMode {
		plan.sharedUnits, err = sharedTierUnits(layout, catalog, plan.units, environment)
		if err != nil {
			return plan, err
		}
	}

	// The egress address is only needed when a chosen root actually asks for it.
	needsCIDR := false
	for _, unit := range plan.units {
		tokens, err := infra.PlaceholdersIn(unit, environment)
		if err != nil {
			return plan, err
		}
		for _, token := range tokens {
			if infra.IsEgressPlaceholder(token) {
				needsCIDR = true
			}
		}
	}
	if needsCIDR {
		plan.apiCIDR, err = resolveAPICIDR(ctx, opts, ask)
		if err != nil {
			return plan, err
		}
	}

	// Compute every write as a dry run first: the confirmation must be about the
	// real result, not a guess at it.
	preview := infra.WriteOptions{Force: opts.force, DryRun: true}
	real := infra.WriteOptions{Force: opts.force}
	plan.forceSet = opts.force

	specs := []infra.EnvSpec{plan.env}
	envResult, err := infra.WriteEnvironmentsConf(layout, specs, preview)
	if err != nil {
		return plan, err
	}
	plan.writes = append(plan.writes, plannedWrite{
		label:  "environments.conf [" + environment + "]",
		result: envResult,
		role:   "which AWS account this environment may touch",
		apply: func(l infra.Layout) (infra.WriteResult, error) {
			return infra.WriteEnvironmentsConf(l, specs, real)
		},
	})

	replacements := map[string]string{}
	if plan.apiCIDR != "" {
		// Both spellings answer to the same address: dev's template asks for the
		// operator's egress, stg's for the office range.
		for _, token := range infra.EgressIPPlaceholders {
			replacements[token] = plan.apiCIDR
		}
	}
	// --set is the general escape: a template that grows a token this build does not
	// know about is still fillable without waiting for a release.
	for token, value := range opts.set {
		replacements[token] = value
	}
	for _, unit := range plan.sharedUnits {
		// No Mode here: the tier roots have no such variable. They are the owner,
		// so there is nothing for them to choose, and writing the key would set a
		// variable the root does not declare.
		request := infra.VarFileRequest{Unit: unit, Env: environment, Region: plan.env.Region}
		result, err := infra.MaterializeVarFile(layout, request, preview)
		if err != nil {
			return plan, err
		}
		plan.writes = append(plan.writes, plannedWrite{
			label:  unit.Name,
			result: result,
			role:   "owns the instance",
			apply: func(l infra.Layout) (infra.WriteResult, error) {
				return infra.MaterializeVarFile(l, request, real)
			},
		})
	}

	for _, unit := range plan.units {
		// The region travels with the request: the templates hardcode one, and a
		// checkout configured for another would otherwise deploy to the template's
		// region while every guard reported agreement.
		request := infra.VarFileRequest{
			Unit:         unit,
			Env:          environment,
			Replacements: replacements,
			Region:       plan.env.Region,
			Mode:         plan.mode,
		}
		result, err := infra.MaterializeVarFile(layout, request, preview)
		if err != nil {
			return plan, err
		}
		// A root with no mode switch is unaffected by the mode, so it creates its
		// own resource in either one. Reporting it as "creates nothing" under shared
		// mode was the opposite of true for the s3 roots, which do create a bucket.
		switchable, err := infra.SupportsMode(unit, environment)
		if err != nil {
			return plan, err
		}
		if !switchable && !unit.Bootstrap && !strings.HasPrefix(unit.Name, "infra-base/") {
			plan.modeless = append(plan.modeless, unit)
		}

		role := ""
		switch {
		case unit.Bootstrap:
			role = "state backend"
		case strings.HasPrefix(unit.Name, "infra-base/"):
			role = "foundation"
		case !switchable:
			role = "creates its own, not shareable"
		case plan.mode == infra.SharedMode:
			role = "resolves shared tier, creates nothing"
		case plan.mode == infra.DedicatedMode:
			role = "creates its own instance"
		}
		plan.writes = append(plan.writes, plannedWrite{
			label:  unit.Name,
			result: result,
			role:   role,
			apply: func(l infra.Layout) (infra.WriteResult, error) {
				return infra.MaterializeVarFile(l, request, real)
			},
		})
	}
	return plan, nil
}

// resolveCredentials settles profile, region and the account they reach.
func resolveCredentials(
	ctx context.Context,
	opts initOptions,
	ask *prompter,
) (profile, region string, caller infra.Caller, err error) {
	profile = opts.profile
	region = strings.TrimSpace(opts.region)

	// With a profile already named, one lookup answers everything.
	if profile != "" || !ask.interactive {
		if ask.interactive {
			// Always asked, even when the profile declares one. Which region the
			// infrastructure is born in is a decision; inheriting it silently from
			// ~/.aws/config is how somebody discovers it after the bill.
			suggestion := region
			if suggestion == "" {
				suggestion = "us-east-2"
			}
			region, err = ask.ask(
				"Which AWS region will the infrastructure be created in?",
				"Every resource lands here. Moving later means recreating them.",
				suggestion, "--region")
			if err != nil {
				return "", "", caller, err
			}
		}
		if region == "" {
			return "", "", caller, fmt.Errorf("no region given\nPass --region (for example --region us-east-2).")
		}
		caller, err = infra.CLIIdentity{}.CallerIdentity(ctx, profile, region)
		if err != nil {
			if opts.account != "" {
				// An explicit account lets a machine without working credentials still
				// write the configuration; the guard will check it at apply time.
				return profile, region, infra.Caller{}, nil
			}
			remedy := "Check the credentials in the environment."
			if profile != "" {
				// By far the most common cause, and the one with a one-line fix.
				remedy = "An expired SSO session is the usual cause:\n  aws sso login --profile " + profile
			}
			return "", "", caller, fmt.Errorf("cannot determine who %s is: %w\n\n%s\n\n"+
				"To write the configuration without reaching AWS at all, state the account\n"+
				"explicitly: --account 123456789012",
				profileLabel(profile), err, remedy)
		}
		return profile, region, caller, nil
	}

	// Interactive with no profile named: show what exists and what each one reaches.
	profiles, err := infra.ListAWSProfiles()
	if err != nil {
		return "", "", caller, err
	}
	if len(profiles) == 0 {
		return "", "", caller, fmt.Errorf("no AWS profiles found in ~/.aws\n" +
			"Configure one (aws configure sso), or pass --profile '' with ambient\n" +
			"credentials and --account to say which account they reach.")
	}

	resolved := infra.ResolveProfiles(ctx, infra.CLIIdentity{}, profiles, region)
	ask.printProfiles(resolved)

	usable := make([]infra.ResolvedProfile, 0, len(resolved))
	for _, entry := range resolved {
		if entry.Usable() {
			usable = append(usable, entry)
		}
	}
	if len(usable) == 0 {
		hint := infra.LoginHint(resolved)
		if hint == "" {
			hint = "Check the credentials for these profiles."
		}
		return "", "", caller, fmt.Errorf("none of the %d profile(s) in ~/.aws resolve right now\n"+
			"An expired SSO session is the usual cause. This revives them:\n\n  %s\n\n"+
			"Then run this command again.", len(resolved), hint)
	}

	preset := usable[0].Profile.Name
	chosen, err := ask.ask(
		"Which AWS profile should be used?",
		"Its account is where everything is created. Check the ACCOUNT column above.",
		preset, "--profile")
	if err != nil {
		return "", "", caller, err
	}
	for _, entry := range resolved {
		if entry.Profile.Name != chosen {
			continue
		}
		if entry.Err != nil {
			return "", "", caller, fmt.Errorf("profile %q does not resolve: %w\n"+
				"  aws sso login --profile %s", chosen, entry.Err, chosen)
		}
		effective := region
		if effective == "" {
			effective = entry.Profile.Region
		}
		if effective == "" {
			effective, err = ask.text("AWS region", "us-east-2", "--region")
			if err != nil {
				return "", "", caller, err
			}
		}
		return chosen, effective, entry.Caller, nil
	}
	return "", "", caller, fmt.Errorf("profile %q is not one of the profiles in ~/.aws", chosen)
}

// resolveAPICIDR settles the address allowed to reach the Kubernetes API.
//
// A detected address is always shown for confirmation rather than used silently:
// getting this wrong locks the operator out of the cluster's API, and it is the
// one value here whose mistake is not obvious until much later.
func resolveAPICIDR(ctx context.Context, opts initOptions, ask *prompter) (string, error) {
	value := strings.TrimSpace(opts.apiCIDR)

	if value == "" && !ask.interactive {
		return "", fmt.Errorf("infra-base/eks needs the address allowed to reach the Kubernetes API\n" +
			"Pass --api-cidr auto to detect this machine's egress address, or give it\n" +
			"explicitly: --api-cidr 203.0.113.7")
	}

	if value == "" || value == "auto" {
		lookup, cancel := context.WithTimeout(ctx, 10*time.Second)
		defer cancel()
		detected, err := infra.DetectEgressIP(lookup, &http.Client{})
		if err != nil {
			if value == "auto" {
				return "", err
			}
			// Interactive with no preference: detection failing is not fatal, the
			// operator can still type the address.
			return ask.ask(
				"Which address may reach the Kubernetes API?",
				"Detection failed, so type it: your public egress address, no mask.",
				"", "--api-cidr")
		}
		if value == "auto" && !ask.interactive {
			return detected, nil
		}
		return ask.ask(
			"Which address may reach the Kubernetes API?",
			"Only this address can talk to the cluster's control plane. "+
				"The default is what this machine appears to come from.",
			detected, "--api-cidr")
	}
	return value, nil
}

func printInitPlan(out io.Writer, layout infra.Layout, plan initPlan) {
	theme := newStyle(out)
	fmt.Fprintf(out, "\n%s\n", theme.bold("==> Configuration"))
	fmt.Fprintf(out, "  environment %s\n", plan.env.Environment)
	fmt.Fprintf(out, "  account     %s\n", plan.env.AccountID)
	fmt.Fprintf(out, "  profile     %s\n", profileLabel(plan.env.Profile))
	fmt.Fprintf(out, "  region      %s\n", plan.env.Region)
	if plan.caller.ARN != "" {
		fmt.Fprintf(out, "  verified as %s\n", plan.caller.ARN)
	}
	if plan.apiCIDR != "" {
		fmt.Fprintf(out, "  api access  %s/32\n", plan.apiCIDR)
	}
	if plan.mode != "" {
		fmt.Fprintf(out, "  datastores  %s\n", plan.mode)
	}

	fmt.Fprintf(out, "\n%s\n\n", theme.bold("==> Files"))
	writer := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(writer, "  FILE\tACTION\tWHAT IT IS\tNOTE")
	for _, write := range plan.writes {
		var notes []string
		if from := write.result.RetargetedFrom; from != "" {
			notes = append(notes, fmt.Sprintf("region %s -> %s", from, plan.env.Region))
		}
		if len(write.result.Pending) > 0 {
			notes = append(notes, "still needs "+strings.Join(write.result.Pending, " "))
		}
		fmt.Fprintf(writer, "  %s\t%s\t%s\t%s\n",
			layout.RepoRel(write.result.Path), write.result.Action,
			write.role, strings.Join(notes, "; "))
	}
	_ = writer.Flush()

	for _, write := range plan.writes {
		if write.result.Action != infra.WriteConflict {
			continue
		}
		fmt.Fprintf(out, "\n  ---- %s differs ----\n%s",
			layout.RepoRel(write.result.Path), indent(strings.TrimRight(write.result.Diff, "\n"), "  "))
		fmt.Fprintln(out)
	}
}

// printSharedTierNotice spells out the obligation that comes with shared mode.
//
// The tier's tfvars are written by init, but applying them stays a separate,
// explicit command: a root in shared mode creates nothing and resolves
// "shared-{env}-{engine}" by name, so if that tier was never applied the failure
// lands later as a bare "not found" from a data source. Naming the commands here
// is the difference between an instruction and a puzzle — and leaving the running
// to the operator keeps the shared tier the deliberate choice it is meant to be.
func printSharedTierNotice(out io.Writer, plan initPlan) {
	if plan.mode != infra.SharedMode {
		return
	}

	theme := newStyle(out)

	// Shared mode with nothing to resolve is worse than a missing warning: every
	// product plan will fail looking up a tier this checkout cannot even configure.
	if len(plan.sharedUnits) == 0 {
		if len(plan.units) == 0 {
			return
		}
		fmt.Fprintf(out, "\n  %s\n", theme.bold(
			"WARNING: shared mode was selected, but no shared tier was found."))
		fmt.Fprintf(out, "  %s\n\n", theme.dim(
			"The products expect shared-"+plan.env.Environment+"-<engine> to exist. Nothing in "+
				"products/shared-resources matches their datastores, so every plan will fail."))
		return
	}
	fmt.Fprintf(out, "\n  %s\n", theme.bold("The shared tier was configured too, but is NOT applied automatically."))
	fmt.Fprintf(out, "  %s\n\n", theme.dim(
		"Your products resolve these instead of creating their own. Apply them first."))
	for _, unit := range plan.sharedUnits {
		name := unit.Name
		if index := strings.LastIndex(name, "/"); index >= 0 {
			name = name[index+1:]
		}
		fmt.Fprintf(out, "    lerian-infra --env %s --target shared-resources/%s --action apply\n",
			plan.env.Environment, name)
	}
	fmt.Fprintln(out)
}

// targetsBootstrap reports whether the bootstrap root is already in the list.
func targetsBootstrap(units []infra.Unit) bool {
	for _, unit := range units {
		if unit.Bootstrap {
			return true
		}
	}
	return false
}

// sharedTierUnits maps the product datastores onto the shared roots that own them.
//
// A product engine with no counterpart in products/shared-resources is skipped
// rather than reported: not every datastore has a shared form, and the operator
// did not ask for this list.
func sharedTierUnits(
	layout infra.Layout,
	catalog infra.Catalog,
	products []infra.Unit,
	env string,
) ([]infra.Unit, error) {
	available := map[string]bool{}
	for _, service := range catalog.Products["shared-resources"] {
		available[service] = true
	}

	seen := map[string]bool{}
	var wanted []string
	for _, unit := range products {
		if !strings.HasPrefix(unit.Name, "products/") {
			continue
		}
		index := strings.LastIndex(unit.Name, "/")
		if index < 0 {
			continue
		}
		engine := unit.Name[index+1:]
		if !available[engine] || seen[engine] {
			continue
		}
		seen[engine] = true
		wanted = append(wanted, engine)
	}
	sort.Strings(wanted)

	var units []infra.Unit
	for _, engine := range wanted {
		stages, err := infra.Resolve(layout, catalog, "shared-resources/"+engine)
		if err != nil {
			return nil, err
		}
		for _, stage := range stages {
			units = append(units, stage.Units...)
		}
	}
	return units, nil
}

// printUnshareableNotice names the chosen roots that shared mode does not reach.
//
// "Shared datastores" reads as "nothing of mine gets created", and for the four
// products that own an S3 bucket that is wrong: a bucket holds one application's
// objects under one policy, one lifecycle and one key, so there is no s3 root in
// the shared tier and the product's own root still creates a real bucket. The
// no-op is correct and silent, which is the worst combination — an operator who
// planned for zero resources finds a bucket, or worse, skips the apply that
// creates the one thing the application needs.
func printUnshareableNotice(out io.Writer, plan initPlan) {
	if plan.mode != infra.SharedMode || len(plan.modeless) == 0 {
		return
	}

	theme := newStyle(out)
	fmt.Fprintf(out, "  %s\n", theme.bold("These are never shared, and still create their own resource:"))
	for _, unit := range plan.modeless {
		fmt.Fprintf(out, "    %s\n", unit.Name)
	}
	fmt.Fprint(out, theme.dim(wrapIndent(
		"A bucket holds one application's objects under one policy, one lifecycle and "+
			"one key, so the shared tier has no s3 root for these to resolve. They are "+
			"applied with the product, like any other of its services.", "    ", 76))+"\n\n")
}

// printModeDisclaimer states what the chosen datastore mode is for.
//
// It is printed after the mode is answered and before the file list, which is the
// last moment where changing the answer costs nothing. Both modes get one: the
// choice has consequences either way, and only telling the operator about one of
// them would read as discouragement rather than information.
func printModeDisclaimer(out io.Writer, plan initPlan) {
	theme := newStyle(out)

	switch plan.mode {
	case infra.SharedMode:
		fmt.Fprintf(out, "\n  %s\n\n", theme.bold("Shared datastores: what they are for"))
		fmt.Fprint(out, wrapIndent(
			"One set of databases serves every product. Use it for dev and staging, "+
				"where several products are exercised at once and paying for a full set "+
				"per product buys nothing.", "    ", 76)+"\n\n")
		fmt.Fprint(out, wrapIndent(
			"The templates size this tier per environment: dev and stg run small and "+
				"single-AZ to stay cheap, prd steps up to m7g/r6g with multi-AZ. So the "+
				"decision here is not about capacity — it is about who shares a failure. "+
				"Every product here lives in the same instances, so a saturated "+
				"connection pool, a runaway query or a failover reaches all of them, and "+
				"you cannot restart or tune one product's database without touching the "+
				"others.", "    ", 76)+"\n")

		// Not blocked: an operator may have reasons, and this tool does not get to
		// overrule them. Made impossible to miss instead — the one use of colour in
		// the whole CLI, and the words carry it alone when colour is unavailable.
		if plan.env.Environment == "prd" {
			fmt.Fprintf(out, "\n  %s\n", theme.alert(
				"WARNING: you are choosing shared datastores for PRODUCTION."))
			fmt.Fprintf(out, "  %s\n", theme.alert(
				"Lerian recommends dedicated datastores per product in prd. Proceeding"))
			fmt.Fprintf(out, "  %s\n", theme.alert(
				"means one product's incident can degrade every other product you run,"))
			fmt.Fprintf(out, "  %s\n", theme.alert(
				"and you are accepting that risk."))
		}
		fmt.Fprintln(out)

	case infra.DedicatedMode:
		fmt.Fprintf(out, "\n  %s\n\n", theme.bold("Dedicated datastores: sizing is yours"))
		fmt.Fprint(out, wrapIndent(
			"Each product gets its own instances, so an incident in one stays in one. "+
				"dev and stg are provisioned at the smallest classes that work "+
				"(db.t4g.micro, db.t3.medium, cache.t4g.micro) to keep them cheap; prd "+
				"steps up to m7g/r6g with multi-AZ, 14-day backups and deletion "+
				"protection.", "    ", 76)+"\n\n")
		fmt.Fprint(out, wrapIndent(
			"Those prd values are a starting point for moderate traffic, not a capacity "+
				"plan for your workload. Only you know your transaction volume, peak "+
				"concurrency and growth, so reviewing instance classes, storage, IOPS, "+
				"connection limits and replica counts in envs/prd.tfvars before applying "+
				"is your responsibility — Lerian ships the templates and the defaults, "+
				"not a sizing for traffic it cannot measure.", "    ", 76)+"\n\n")
	}
}
