package infra

import (
	"context"
	"encoding/json"
	"fmt"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// fakeTerraform stands in for the CLI. The shell version could only be tested by
// putting a stub binary on PATH and reading back the argv it recorded; here the
// ordering, the guards and the merge are exercised directly.
type fakeTerraform struct {
	mu sync.Mutex

	// calls is every call in the order it happened, as "<phase> <unit>".
	calls []string
	// initOptions is the InitOptions each unit was initialised with.
	initOptions map[string]InitOptions
	// planOptions is the PlanOptions each unit was planned with.
	planOptions map[string]PlanOptions

	// changes is what ShowPlan reports per unit. A unit that is absent reports none.
	changes map[string]Changes
	// outputs is what Output returns per unit.
	outputs map[string]map[string]json.RawMessage
	// failures makes one "<phase> <unit>" call fail.
	failures map[string]error
	// delay is how long each call takes, for the concurrency assertions.
	delay time.Duration

	inFlight atomic.Int64
	peak     atomic.Int64
}

func newFakeTerraform() *fakeTerraform {
	return &fakeTerraform{
		initOptions: map[string]InitOptions{},
		planOptions: map[string]PlanOptions{},
		changes:     map[string]Changes{},
		outputs:     map[string]map[string]json.RawMessage{},
		failures:    map[string]error{},
	}
}

func (f *fakeTerraform) record(phase string, unit Unit) error {
	key := phase + " " + unit.Name

	f.mu.Lock()
	f.calls = append(f.calls, key)
	err := f.failures[key]
	delay := f.delay
	f.mu.Unlock()

	if delay > 0 {
		current := f.inFlight.Add(1)
		for {
			peak := f.peak.Load()
			if current <= peak || f.peak.CompareAndSwap(peak, current) {
				break
			}
		}
		time.Sleep(delay)
		f.inFlight.Add(-1)
	}
	return err
}

func (f *fakeTerraform) Init(_ context.Context, unit Unit, opts InitOptions) error {
	if err := f.record("init", unit); err != nil {
		return err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.initOptions[unit.Name] = opts
	return nil
}

func (f *fakeTerraform) Plan(_ context.Context, unit Unit, opts PlanOptions) (bool, error) {
	if err := f.record("plan", unit); err != nil {
		return false, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.planOptions[unit.Name] = opts
	return !f.changes[unit.Name].Empty(), nil
}

func (f *fakeTerraform) ShowPlan(_ context.Context, unit Unit, _ string) (Changes, error) {
	if err := f.record("show", unit); err != nil {
		return Changes{}, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.changes[unit.Name], nil
}

func (f *fakeTerraform) Apply(_ context.Context, unit Unit, _ string) error {
	return f.record("apply", unit)
}

func (f *fakeTerraform) Output(_ context.Context, unit Unit) (map[string]json.RawMessage, error) {
	if err := f.record("output", unit); err != nil {
		return nil, err
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.outputs[unit.Name], nil
}

// phase returns the units that saw one phase, in call order.
func (f *fakeTerraform) phase(name string) []string {
	f.mu.Lock()
	defer f.mu.Unlock()

	var units []string
	for _, call := range f.calls {
		if len(call) > len(name) && call[:len(name)+1] == name+" " {
			units = append(units, call[len(name)+1:])
		}
	}
	return units
}

// recordingProgress captures the checklist a run would render.
type recordingProgress struct {
	mu sync.Mutex

	started  []string
	updates  []string
	finished bool
	failed   bool
}

func (p *recordingProgress) Start(units []string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.started = append([]string(nil), units...)
}

func (p *recordingProgress) Update(unit string, status Status, _, _ string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.updates = append(p.updates, fmt.Sprintf("%s=%s", unit, status))
}

func (p *recordingProgress) Finish(failed bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.finished = true
	p.failed = failed
}

func (p *recordingProgress) sawStatus(unit string, status Status) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, update := range p.updates {
		if update == fmt.Sprintf("%s=%s", unit, status) {
			return true
		}
	}
	return false
}

// newTestRunner wires a Runner over the fake, with a run directory that goes away
// with the test.
func newTestRunner(t *testing.T, terraform Terraform, progress Progress, jobs int) *Runner {
	t.Helper()
	runner, err := NewRunner(RunnerOptions{
		Env:       "dev",
		Backend:   Backend{Path: "/repo/examples/aws/backend/dev.hcl", Bucket: "lerian-tfstate-dev-123456789012"},
		Terraform: terraform,
		Jobs:      jobs,
		Progress:  progress,
		RunDir:    t.TempDir(),
	})
	if err != nil {
		t.Fatalf("NewRunner: %v", err)
	}
	return runner
}

func units(names ...string) []Unit {
	list := make([]Unit, 0, len(names))
	for _, name := range names {
		list = append(list, Unit{Dir: "/repo/examples/aws/" + name, Name: name})
	}
	return list
}
