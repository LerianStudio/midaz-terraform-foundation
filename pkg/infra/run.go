package infra

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ErrAborted is returned when the operator declines the confirmation. It is not a
// failure: nothing ran.
var ErrAborted = errors.New("infra: aborted by the operator")

// RunnerOptions configures a Runner. Everything in it is resolved and verified
// before the Runner exists: the account guard runs before this, not inside it.
type RunnerOptions struct {
	Layout Layout
	// Env is dev, stg or prd.
	Env string
	// Backend is backend/<env>.hcl. Its zero value is valid only for a run whose
	// units are all bootstrap.
	Backend Backend
	// Terraform executes the roots.
	Terraform Terraform
	// Jobs is how many units of one stage run at once. Stages are always ordered.
	Jobs int
	// Progress observes the run. Nil discards.
	Progress Progress
	// RunDir holds the saved plan files. It must already exist and should be 0700:
	// a saved plan can contain values read from state.
	RunDir string
}

// Runner walks stages in order and the units inside a stage in parallel.
type Runner struct {
	opts RunnerOptions
}

// NewRunner validates the options and returns a Runner.
func NewRunner(opts RunnerOptions) (*Runner, error) {
	if opts.Terraform == nil {
		return nil, errors.New("infra: RunnerOptions.Terraform is required")
	}
	if !ValidEnvironment(opts.Env) {
		return nil, fmt.Errorf("infra: invalid environment %q", opts.Env)
	}
	if opts.RunDir == "" {
		return nil, errors.New("infra: RunnerOptions.RunDir is required")
	}
	if opts.Jobs < 1 {
		opts.Jobs = 1
	}
	opts.Progress = progressOr(opts.Progress)
	return &Runner{opts: opts}, nil
}

// UnitResult is what one root did in one phase.
type UnitResult struct {
	Unit    Unit
	Changes Changes
	Elapsed time.Duration
	Err     error
}

// StageResult is one stage of a run.
type StageResult struct {
	Stage Stage
	// Plans holds one entry per unit, in the stage's order.
	Plans []UnitResult
	// Applies is empty for ActionPlan and for a stage that was never confirmed.
	Applies []UnitResult
	// Blocked marks a stage that could not be planned because an earlier stage in
	// this same run still has resources to create.
	//
	// This is not a failure. Every layer here resolves the one below it in AWS — eks
	// finds the VPC by tag, the datastores find its database subnets — and a plan
	// sees only what AWS already has, never what an earlier stage of the same run
	// has merely planned. On a first run that is the normal state of affairs, and
	// reporting it as FAILED sent operators to debug a configuration that was right.
	Blocked bool
	// BlockedBy names the stage whose pending creations explain it.
	BlockedBy string
}

// Changed reports whether any plan in the stage holds a change.
func (s StageResult) Changed() bool {
	for _, plan := range s.Plans {
		if !plan.Changes.Empty() {
			return true
		}
	}
	return false
}

// Confirm is asked once per stage, after every unit of that stage has been
// planned and before any of them is applied. Returning an error aborts the run;
// return ErrAborted to say the operator declined.
//
// The saved plans are what gets applied, so what runs is exactly what this
// callback was shown.
type Confirm func(stage Stage, plans []UnitResult) error

// Execute plans and, for apply and destroy, applies the stages in order.
//
// The two phases are separate on purpose. Planning every unit of a stage first
// means the operator sees the whole stage — every create, update and delete — and
// answers once, instead of confirming service by service with no idea what the
// next answer will contain. The apply phase then runs the saved plan files and
// never re-plans.
//
// A failure stops the run: later stages are not started, because they depend on
// the stage that failed. Units within the failing stage all get their turn, so the
// operator sees every problem at once rather than the first one.
func (r *Runner) Execute(
	ctx context.Context,
	stages []Stage,
	action Action,
	confirm Confirm,
) ([]StageResult, error) {
	progress := r.opts.Progress

	names := make([]string, 0)
	for _, unit := range Units(stages) {
		names = append(names, unit.Name)
	}
	progress.Start(names)

	destroy := action == ActionDestroy
	results := make([]StageResult, 0, len(stages))

	for index, stage := range stages {
		result := StageResult{Stage: stage}
		result.Plans = r.runUnits(ctx, stage.Units, func(ctx context.Context, unit Unit) (Changes, error) {
			return r.planUnit(ctx, unit, destroy)
		}, planVerb(destroy), false)

		results = append(results, result)
		if err := firstError(result.Plans); err != nil {
			// Before calling this a failure, ask whether it could have succeeded at
			// all. If an earlier stage of this same run still has resources to create,
			// the things this stage looks up do not exist yet, and no configuration
			// could have planned. That is the normal first run, not a fault.
			if blocker := pendingCreator(results[:len(results)-1]); action == ActionPlan && blocker != "" {
				results[len(results)-1].Blocked = true
				results[len(results)-1].BlockedBy = blocker
				for _, unit := range stage.Units {
					progress.Update(unit.Name, StatusSkipped,
						fmt.Sprintf("cannot be planned until %s is applied.", blocker), "")
				}
				// Everything below this stage is blocked for the same reason, so say
				// so instead of attempting each one and collecting identical failures.
				for _, later := range stages[index+1:] {
					blockedResult := StageResult{Stage: later, Blocked: true, BlockedBy: blocker}
					results = append(results, blockedResult)
					for _, unit := range later.Units {
						progress.Update(unit.Name, StatusSkipped,
							fmt.Sprintf("cannot be planned until %s is applied.", blocker), "")
					}
				}
				progress.Finish(false)
				return results, nil
			}

			progress.Finish(true)
			return results, fmt.Errorf("infra: plan failed in stage %q (%d of %d); nothing was applied "+
				"and later stages were not started: %w", stage.Name, index+1, len(stages), err)
		}

		if action == ActionPlan {
			continue
		}

		if confirm != nil {
			if err := confirm(stage, result.Plans); err != nil {
				progress.Finish(true)
				for _, unit := range stage.Units {
					progress.Update(unit.Name, StatusSkipped, "not confirmed.", "")
				}
				return results, err
			}
		}

		// terraform apply of a saved plan reports no counts of its own, but it
		// does not need to: applying a saved plan performs exactly the changes
		// that plan described. Carrying the planned counts across is what lets
		// the apply line say what happened instead of "no changes".
		planned := make(map[string]Changes, len(result.Plans))
		for _, plan := range result.Plans {
			planned[plan.Unit.Name] = plan.Changes
		}

		applies := r.runUnits(ctx, stage.Units, func(ctx context.Context, unit Unit) (Changes, error) {
			return planned[unit.Name], r.opts.Terraform.Apply(ctx, unit, r.PlanFile(unit))
		}, applyVerb(destroy), true)
		results[len(results)-1].Applies = applies

		if err := firstError(applies); err != nil {
			progress.Finish(true)
			return results, fmt.Errorf("infra: %s failed in stage %q (%d of %d); later stages were not "+
				"started. Terraform is idempotent: re-run the same command once the cause is fixed: %w",
				action, stage.Name, index+1, len(stages), err)
		}
	}

	progress.Finish(false)
	return results, nil
}

// planUnit initialises the root and writes its saved plan.
func (r *Runner) planUnit(ctx context.Context, unit Unit, destroy bool) (Changes, error) {
	if err := r.opts.Terraform.Init(ctx, unit, initOptionsFor(unit, r.opts.Backend, r.opts.Env)); err != nil {
		return Changes{}, err
	}
	planFile := r.PlanFile(unit)
	if _, err := r.opts.Terraform.Plan(ctx, unit, PlanOptions{
		VarFile: VarFile(unit, r.opts.Env),
		Out:     planFile,
		Destroy: destroy,
	}); err != nil {
		return Changes{}, err
	}
	return r.opts.Terraform.ShowPlan(ctx, unit, planFile)
}

// Outputs reads every output of every unit, in order.
func (r *Runner) Outputs(ctx context.Context, units []Unit) (map[string]map[string]json.RawMessage, error) {
	progress := r.opts.Progress
	names := make([]string, 0, len(units))
	for _, unit := range units {
		names = append(names, unit.Name)
	}
	progress.Start(names)

	outputs := make(map[string]map[string]json.RawMessage, len(units))
	for _, unit := range units {
		progress.Update(unit.Name, StatusRunning, "reading the outputs...", "")
		if err := r.opts.Terraform.Init(ctx, unit, initOptionsFor(unit, r.opts.Backend, r.opts.Env)); err != nil {
			progress.Update(unit.Name, StatusFail, err.Error(),
				"Confirm this stack has been applied in this environment.")
			progress.Finish(true)
			return outputs, err
		}
		values, err := r.opts.Terraform.Output(ctx, unit)
		if err != nil {
			progress.Update(unit.Name, StatusFail, err.Error(),
				"Confirm this stack has been applied in this environment.")
			progress.Finish(true)
			return outputs, err
		}
		outputs[unit.Name] = values
		progress.Update(unit.Name, StatusOK, fmt.Sprintf("%d output(s).", len(values)), "")
	}
	progress.Finish(false)
	return outputs, nil
}

// HelmValues merges the Helm handoff of every unit into one document.
func (r *Runner) HelmValues(ctx context.Context, units []Unit) (Document, error) {
	// The Layout travels through so a product in shared mode can have its values
	// built from the tier that owns its datastore, instead of requiring an apply of
	// a root that creates nothing.
	return CollectHelmValuesFrom(ctx, r.opts.Terraform, r.opts.Layout, units,
		r.opts.Backend, r.opts.Env, r.opts.Progress)
}

// PlanFile is where the saved plan of one unit lives for this run.
func (r *Runner) PlanFile(unit Unit) string {
	return filepath.Join(r.opts.RunDir, unit.slug()+".tfplan")
}

// runUnits executes work over the units with at most Jobs in flight, and returns
// the results in the order the units were given so the table is stable.
func (r *Runner) runUnits(
	ctx context.Context,
	units []Unit,
	work func(context.Context, Unit) (Changes, error),
	verb string,
	applied bool,
) []UnitResult {
	progress := r.opts.Progress
	results := make([]UnitResult, len(units))

	semaphore := make(chan struct{}, r.opts.Jobs)
	var wg sync.WaitGroup
	wg.Add(len(units))

	for i, unit := range units {
		go func(i int, unit Unit) {
			defer wg.Done()
			semaphore <- struct{}{}
			defer func() { <-semaphore }()

			progress.Update(unit.Name, StatusRunning, verb+"...", "")
			start := time.Now()
			changes, err := work(ctx, unit)
			result := UnitResult{Unit: unit, Changes: changes, Elapsed: time.Since(start), Err: err}
			results[i] = result

			if err != nil {
				progress.Update(unit.Name, StatusFail, err.Error(),
					"See this stack's full log in the run directory.")
				return
			}
			progress.Update(unit.Name, StatusOK, describeChanges(changes, result.Elapsed, applied), "")
		}(i, unit)
	}
	wg.Wait()
	return results
}

// describeChanges renders one unit's outcome.
//
// Two conventions, both for the reader. The tense follows Terraform's own: a plan
// says what it would do, an apply says what it did. And a count of zero is left
// out entirely — "42 to add, 0 to change, 0 to destroy" spends most of its width
// on the two facts that did not happen, and in a list of six stacks that is what
// the eye has to filter before finding the number that matters.
//
// The elapsed time is separated by a tab so a renderer can column-align it. A
// consumer that does not care can print the string as it is; the tab reads as
// whitespace.
func describeChanges(changes Changes, elapsed time.Duration, applied bool) string {
	return summarizeChanges(changes, applied) + "\t" + roundElapsed(elapsed)
}

// summarizeChanges is the counts alone, without timing.
func summarizeChanges(changes Changes, applied bool) string {
	if changes.Empty() {
		return "no changes"
	}
	verbs := [3]string{"to add", "to change", "to destroy"}
	if applied {
		verbs = [3]string{"added", "changed", "destroyed"}
	}
	counts := [3]int{changes.Create, changes.Update, changes.Delete}

	parts := make([]string, 0, 3)
	for i, count := range counts {
		if count == 0 {
			continue
		}
		parts = append(parts, fmt.Sprintf("%d %s", count, verbs[i]))
	}
	return strings.Join(parts, ", ")
}

// roundElapsed keeps the timing column narrow: whole seconds under a minute, and
// no sub-second noise above it.
func roundElapsed(d time.Duration) string {
	if d < time.Minute {
		return d.Round(time.Second).String()
	}
	return d.Round(time.Second).String()
}

func firstError(results []UnitResult) error {
	for _, result := range results {
		if result.Err != nil {
			return result.Err
		}
	}
	return nil
}

func planVerb(destroy bool) string {
	if destroy {
		return "planning destroy"
	}
	return "planning"
}

func applyVerb(destroy bool) string {
	if destroy {
		return "destroying"
	}
	return "applying"
}

// initOptionsFor picks how a root is initialised. bootstrap is the exception in
// the whole repository: it creates the backend, so it cannot use it, and runs on
// local state with one workspace per environment instead.
func initOptionsFor(unit Unit, backend Backend, env string) InitOptions {
	if unit.Bootstrap {
		return InitOptions{Workspace: env}
	}
	return InitOptions{BackendFile: backend.Path, StateKey: unit.StateKey()}
}

// FileLogs sends the raw Terraform output of each unit to its own file, which is
// what makes a parallel stage readable after the fact: the terminal shows the
// checklist, the files hold the detail.
type FileLogs struct {
	dir string

	mu    sync.Mutex
	files map[string]*os.File
}

// NewFileLogs writes one log per unit into dir.
func NewFileLogs(dir string) *FileLogs {
	return &FileLogs{dir: dir, files: map[string]*os.File{}}
}

// Writer returns the log of one unit, opening it on first use. It is safe to call
// from several goroutines. A file that cannot be opened yields io.Discard rather
// than failing the run: losing the log is not a reason to lose the deploy.
func (l *FileLogs) Writer(unit Unit) io.Writer {
	l.mu.Lock()
	defer l.mu.Unlock()

	if file, ok := l.files[unit.Name]; ok {
		return file
	}
	file, err := os.OpenFile(l.Path(unit), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return io.Discard
	}
	l.files[unit.Name] = file
	return file
}

// Path is where the log of one unit lives.
func (l *FileLogs) Path(unit Unit) string {
	return filepath.Join(l.dir, unit.slug()+".log")
}

// Close closes every log opened so far.
func (l *FileLogs) Close() error {
	l.mu.Lock()
	defer l.mu.Unlock()

	var err error
	for _, file := range l.files {
		if closeErr := file.Close(); closeErr != nil && err == nil {
			err = closeErr
		}
	}
	l.files = map[string]*os.File{}
	return err
}

// pendingCreator names the earliest stage that still has resources to create, or
// "" when everything above has already been applied.
//
// It is the whole test for "this stage never had a chance": a stage that resolves
// its VPC by tag cannot plan while the stage that creates that VPC has 42 things
// still to add.
func pendingCreator(earlier []StageResult) string {
	for _, result := range earlier {
		for _, plan := range result.Plans {
			if plan.Err == nil && plan.Changes.Create > 0 {
				return result.Stage.Name
			}
		}
	}
	return ""
}

// Blocked reports whether any stage could not be planned because a stage above it
// has not been applied yet.
func Blocked(results []StageResult) bool {
	for _, result := range results {
		if result.Blocked {
			return true
		}
	}
	return false
}
