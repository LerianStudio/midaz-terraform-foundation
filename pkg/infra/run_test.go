package infra

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The two-phase rule: every unit of a stage is planned, the operator confirms
// once, and only then is anything applied. Confirming service by service would ask
// the operator to answer with no idea what the next answer contains.
func TestExecutePlansTheWholeStageBeforeApplyingAnyOfIt(t *testing.T) {
	terraform := newFakeTerraform()
	stage := Stage{Name: "midaz", Units: units(
		"products/midaz/postgres", "products/midaz/valkey", "products/midaz/rabbitmq")}
	runner := newTestRunner(t, terraform, nil, 1)

	var confirmedWith int
	_, err := runner.Execute(context.Background(), []Stage{stage}, ActionApply,
		func(_ Stage, plans []UnitResult) error {
			confirmedWith = len(plans)
			// Nothing may have been applied at the moment the operator is asked.
			if applied := terraform.phase("apply"); len(applied) != 0 {
				t.Errorf("%d unit(s) were applied before the confirmation: %v", len(applied), applied)
			}
			if planned := terraform.phase("plan"); len(planned) != 3 {
				t.Errorf("the confirmation came after %d plans, want all 3: %v", len(planned), planned)
			}
			return nil
		})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if confirmedWith != 3 {
		t.Errorf("the confirmation saw %d plans, want 3", confirmedWith)
	}
	if applied := terraform.phase("apply"); len(applied) != 3 {
		t.Errorf("applied %v, want all three units", applied)
	}
}

func TestExecuteConfirmsOncePerStageAndKeepsTheStagesOrdered(t *testing.T) {
	terraform := newFakeTerraform()
	stages := []Stage{
		{Name: "infra-base/vpc", Units: units("infra-base/vpc")},
		{Name: "infra-base/eks", Units: units("infra-base/eks")},
	}
	runner := newTestRunner(t, terraform, nil, 4)

	var confirmations []string
	_, err := runner.Execute(context.Background(), stages, ActionApply,
		func(stage Stage, _ []UnitResult) error {
			confirmations = append(confirmations, stage.Name)
			return nil
		})
	if err != nil {
		t.Fatalf("Execute: %v", err)
	}

	if got := strings.Join(confirmations, ","); got != "infra-base/vpc,infra-base/eks" {
		t.Errorf("confirmations = %q, want one per stage in order", got)
	}
	// The eks stage must not have been planned before the vpc stage was applied:
	// eks depends on the network the vpc stage creates.
	want := []string{
		"init infra-base/vpc", "plan infra-base/vpc", "show infra-base/vpc",
		"apply infra-base/vpc",
		"init infra-base/eks", "plan infra-base/eks", "show infra-base/eks",
		"apply infra-base/eks",
	}
	if got := strings.Join(terraform.calls, "|"); got != strings.Join(want, "|") {
		t.Errorf("calls =\n  %s\nwant\n  %s", got, strings.Join(want, "|"))
	}
}

func TestExecuteAppliesTheSavedPlanAndNeverReplans(t *testing.T) {
	terraform := newFakeTerraform()
	unit := units("products/midaz/postgres")[0]
	runner := newTestRunner(t, terraform, nil, 1)

	if _, err := runner.Execute(context.Background(),
		[]Stage{{Name: "midaz", Units: []Unit{unit}}}, ActionApply, nil); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	if got := len(terraform.phase("plan")); got != 1 {
		t.Errorf("terraform plan ran %d times, want exactly 1: the apply phase must consume "+
			"the saved plan so what runs is what was shown", got)
	}
	if got := terraform.planOptions[unit.Name].Out; got != runner.PlanFile(unit) {
		t.Errorf("plan -out = %q, want %q", got, runner.PlanFile(unit))
	}
}

func TestExecuteAbortsWithoutApplyingWhenTheOperatorDeclines(t *testing.T) {
	terraform := newFakeTerraform()
	progress := &recordingProgress{}
	runner := newTestRunner(t, terraform, progress, 1)

	_, err := runner.Execute(context.Background(),
		[]Stage{{Name: "midaz", Units: units("products/midaz/postgres")}}, ActionApply,
		func(Stage, []UnitResult) error { return ErrAborted })

	if !errors.Is(err, ErrAborted) {
		t.Fatalf("error = %v, want ErrAborted", err)
	}
	if applied := terraform.phase("apply"); len(applied) != 0 {
		t.Errorf("applied %v after the operator declined", applied)
	}
	if !progress.sawStatus("products/midaz/postgres", StatusSkipped) {
		t.Errorf("the declined unit was not reported as skipped: %v", progress.updates)
	}
}

func TestExecuteStopsAtTheFailingStageAndLeavesTheRestUntouched(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.failures["plan infra-base/eks"] = errors.New("subnet tag not found")
	stages := []Stage{
		{Name: "infra-base/eks", Units: units("infra-base/eks")},
		{Name: "midaz", Units: units("products/midaz/postgres")},
	}
	runner := newTestRunner(t, terraform, nil, 1)

	results, err := runner.Execute(context.Background(), stages, ActionApply, nil)
	if err == nil {
		t.Fatal("Execute succeeded over a failing plan")
	}
	if !strings.Contains(err.Error(), "nothing was applied") {
		t.Errorf("error = %q, want it to say nothing was applied", err)
	}
	if len(results) != 1 {
		t.Errorf("got %d stage results, want only the failing one", len(results))
	}
	for _, call := range terraform.calls {
		if strings.Contains(call, "products/midaz") {
			t.Errorf("the later stage ran anyway: %v", terraform.calls)
			break
		}
	}
}

// Units of one stage all get their turn even when one of them fails, so the
// operator sees every problem at once instead of one per re-run.
func TestExecuteRunsEveryUnitOfAFailingStage(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.failures["plan products/midaz/postgres"] = errors.New("credentials expired")
	stage := Stage{Name: "midaz", Units: units(
		"products/midaz/postgres", "products/midaz/valkey", "products/midaz/rabbitmq")}
	runner := newTestRunner(t, terraform, nil, 4)

	results, err := runner.Execute(context.Background(), []Stage{stage}, ActionPlan, nil)
	if err == nil {
		t.Fatal("Execute succeeded over a failing plan")
	}
	if got := len(terraform.phase("plan")); got != 3 {
		t.Errorf("%d units were planned, want all 3", got)
	}
	var failures int
	for _, plan := range results[0].Plans {
		if plan.Err != nil {
			failures++
		}
	}
	if failures != 1 {
		t.Errorf("got %d failures in the stage result, want 1", failures)
	}
}

func TestExecuteRunsTheUnitsOfAStageInParallelUpToJobs(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.delay = 30 * time.Millisecond
	stage := Stage{Name: "midaz", Units: units(
		"products/midaz/postgres", "products/midaz/valkey",
		"products/midaz/rabbitmq", "products/midaz/documentdb")}
	runner := newTestRunner(t, terraform, nil, 2)

	if _, err := runner.Execute(context.Background(), []Stage{stage}, ActionPlan, nil); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	peak := terraform.peak.Load()
	if peak < 2 {
		t.Errorf("peak concurrency was %d, want 2: the services of a product have separate "+
			"state and separate locks, so they run in parallel", peak)
	}
	if peak > 2 {
		t.Errorf("peak concurrency was %d, want at most --jobs (2)", peak)
	}
}

func TestExecutePassesTheBackendAndTheStateKeyToEveryInit(t *testing.T) {
	terraform := newFakeTerraform()
	unit := units("products/midaz/postgres")[0]
	runner := newTestRunner(t, terraform, nil, 1)

	if _, err := runner.Execute(context.Background(),
		[]Stage{{Name: "midaz", Units: []Unit{unit}}}, ActionPlan, nil); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	options := terraform.initOptions[unit.Name]
	if options.BackendFile != "/repo/examples/aws/backend/dev.hcl" {
		t.Errorf("BackendFile = %q", options.BackendFile)
	}
	if options.StateKey != unit.StateKey() {
		t.Errorf("StateKey = %q, want %q", options.StateKey, unit.StateKey())
	}
	if options.Workspace != "" {
		t.Errorf("Workspace = %q, want empty: only bootstrap uses workspaces", options.Workspace)
	}
}

// bootstrap creates the backend and therefore cannot use it: local state, one
// workspace per environment, which is what its own precondition asserts.
func TestExecuteGivesBootstrapLocalStateAndAWorkspace(t *testing.T) {
	terraform := newFakeTerraform()
	unit := Unit{Dir: "/repo/examples/aws/bootstrap", Name: "bootstrap", Bootstrap: true}
	runner := newTestRunner(t, terraform, nil, 1)

	if _, err := runner.Execute(context.Background(),
		[]Stage{{Name: "bootstrap", Units: []Unit{unit}}}, ActionPlan, nil); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	options := terraform.initOptions["bootstrap"]
	if options.BackendFile != "" {
		t.Errorf("BackendFile = %q, want empty: bootstrap is the stack that creates it", options.BackendFile)
	}
	if options.Workspace != "dev" {
		t.Errorf("Workspace = %q, want dev", options.Workspace)
	}
}

func TestExecutePlansDestroyInReverse(t *testing.T) {
	terraform := newFakeTerraform()
	unit := units("products/midaz/postgres")[0]
	runner := newTestRunner(t, terraform, nil, 1)

	if _, err := runner.Execute(context.Background(),
		[]Stage{{Name: "midaz", Units: []Unit{unit}}}, ActionDestroy, nil); err != nil {
		t.Fatalf("Execute: %v", err)
	}
	if !terraform.planOptions[unit.Name].Destroy {
		t.Error("the destroy action planned a build")
	}
}

func TestExecuteDeclaresEveryUnitBeforeStarting(t *testing.T) {
	// The wizard renders a checklist: the operator has to see how many stacks there
	// are and which have not started, not watch rows appear one at a time.
	terraform := newFakeTerraform()
	progress := &recordingProgress{}
	stages := []Stage{
		{Name: "infra-base/vpc", Units: units("infra-base/vpc")},
		{Name: "midaz", Units: units("products/midaz/postgres", "products/midaz/valkey")},
	}
	runner := newTestRunner(t, terraform, progress, 4)

	if _, err := runner.Execute(context.Background(), stages, ActionPlan, nil); err != nil {
		t.Fatalf("Execute: %v", err)
	}

	want := "infra-base/vpc,products/midaz/postgres,products/midaz/valkey"
	if got := strings.Join(progress.started, ","); got != want {
		t.Errorf("Start(%q), want %q", got, want)
	}
	if !progress.finished || progress.failed {
		t.Errorf("Finish(failed=%v) after a clean run, finished=%v", progress.failed, progress.finished)
	}
}

func TestNewRunnerRejectsAnIncompleteConfiguration(t *testing.T) {
	tests := []struct {
		name   string
		opts   RunnerOptions
		wantIn string
	}{
		{"no terraform", RunnerOptions{Env: "dev", RunDir: "/tmp"}, "Terraform is required"},
		{"bad environment", RunnerOptions{Env: "prod", Terraform: newFakeTerraform(), RunDir: "/tmp"},
			`invalid environment "prod"`},
		{"no run dir", RunnerOptions{Env: "dev", Terraform: newFakeTerraform()}, "RunDir is required"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := NewRunner(test.opts)
			if err == nil {
				t.Fatal("NewRunner succeeded, want an error")
			}
			if !strings.Contains(err.Error(), test.wantIn) {
				t.Errorf("error = %q, want it to contain %q", err, test.wantIn)
			}
		})
	}
}

func TestOutputsReadsEveryUnitInOrder(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.outputs["products/midaz/postgres"] = outputs(map[string]string{"endpoint": `"pg.internal"`})
	terraform.outputs["products/midaz/valkey"] = outputs(map[string]string{"endpoint": `"valkey.internal"`})
	runner := newTestRunner(t, terraform, nil, 1)

	all, err := runner.Outputs(context.Background(),
		units("products/midaz/postgres", "products/midaz/valkey"))
	if err != nil {
		t.Fatalf("Outputs: %v", err)
	}
	if len(all) != 2 {
		t.Fatalf("got %d units, want 2", len(all))
	}
	if string(all["products/midaz/valkey"]["endpoint"]) != `"valkey.internal"` {
		t.Errorf("outputs = %v", all)
	}
	// Read-only, but still an init: the state lives in S3 and the working directory
	// may hold another environment's backend.
	if got := len(terraform.phase("init")); got != 2 {
		t.Errorf("%d inits, want one per unit", got)
	}
}

func TestOutputsStopsAtTheFirstFailure(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.failures["output products/midaz/postgres"] = errors.New("no state found")
	runner := newTestRunner(t, terraform, nil, 1)

	_, err := runner.Outputs(context.Background(),
		units("products/midaz/postgres", "products/midaz/valkey"))
	if err == nil {
		t.Fatal("Outputs succeeded over a missing state")
	}
	for _, call := range terraform.calls {
		if strings.Contains(call, "valkey") {
			t.Errorf("kept reading after the failure: %v", terraform.calls)
			break
		}
	}
}

func TestHelmValuesGoesThroughTheRunnersBackendAndEnvironment(t *testing.T) {
	terraform := newFakeTerraform()
	terraform.outputs["products/midaz/postgres"] = outputs(map[string]string{
		"helm_values": `{"DB_HOST":"pg.internal"}`,
	})
	unit := units("products/midaz/postgres")[0]
	runner := newTestRunner(t, terraform, nil, 1)

	document, err := runner.HelmValues(context.Background(), []Unit{unit})
	if err != nil {
		t.Fatalf("HelmValues: %v", err)
	}
	if document.Values["DB_HOST"] != "pg.internal" {
		t.Errorf("Values = %v", document.Values)
	}
	if got := terraform.initOptions[unit.Name].StateKey; got != unit.StateKey() {
		t.Errorf("StateKey = %q, want %q", got, unit.StateKey())
	}
}

func TestStageResultChangedReportsWhetherAnythingWouldMove(t *testing.T) {
	quiet := StageResult{Plans: []UnitResult{{Changes: Changes{}}, {Changes: Changes{}}}}
	if quiet.Changed() {
		t.Error("Changed() = true over two empty plans")
	}
	busy := StageResult{Plans: []UnitResult{{Changes: Changes{}}, {Changes: Changes{Update: 1}}}}
	if !busy.Changed() {
		t.Error("Changed() = false with an update pending")
	}
}

func TestFileLogsGivesEachUnitItsOwnFile(t *testing.T) {
	dir := t.TempDir()
	logs := NewFileLogs(dir)
	t.Cleanup(func() { _ = logs.Close() })

	postgres := units("products/midaz/postgres")[0]
	valkey := units("products/midaz/valkey")[0]

	if _, err := io.WriteString(logs.Writer(postgres), "planning postgres\n"); err != nil {
		t.Fatalf("write: %v", err)
	}
	// A second call for the same unit must append to the same file, not truncate:
	// the plan and the apply phases both write to it.
	if _, err := io.WriteString(logs.Writer(postgres), "applying postgres\n"); err != nil {
		t.Fatalf("write: %v", err)
	}
	if _, err := io.WriteString(logs.Writer(valkey), "planning valkey\n"); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := logs.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	contents, err := os.ReadFile(logs.Path(postgres))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if got := string(contents); got != "planning postgres\napplying postgres\n" {
		t.Errorf("postgres log = %q", got)
	}
	if filepath.Base(logs.Path(valkey)) != "products-midaz-valkey.log" {
		t.Errorf("valkey log = %q, want the slug of the unit name", logs.Path(valkey))
	}
}
