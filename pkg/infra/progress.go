package infra

// Status is the state of one unit of a run.
//
// The set is deliberately the same as session.StepStatus and preflight.Status: a
// run is rendered as a checklist in both faces, and a middle layer that invented
// its own vocabulary would only make each consumer translate it.
type Status string

const (
	// StatusPending is declared but not started.
	StatusPending Status = "pending"
	// StatusRunning is in flight.
	StatusRunning Status = "running"
	// StatusOK finished without error.
	StatusOK Status = "ok"
	// StatusFail finished with an error.
	StatusFail Status = "fail"
	// StatusWarn finished, but something the operator should read happened —
	// a root that exposes no helm_values, for instance.
	StatusWarn Status = "warn"
	// StatusSkipped was never attempted: an earlier stage failed, or the unit is
	// bootstrap in a destroy run.
	StatusSkipped Status = "skipped"
)

// Progress observes a run while it happens. It is the only channel this package
// has to the operator: nothing here prints, so the same run drives a terminal and
// the wizard's polled checklist without either being special.
//
// The three methods are Start/Update/Finish because that is the shape both
// consumers already have. session.Job is Start(names...)/Set/Finish, so the wizard
// adapter is a mechanical forward through the session store's lock; a terminal
// writer is the same three cases.
//
// Start exists as a separate call, rather than letting rows appear as they run,
// because the wizard renders a checklist: the operator has to see how many stacks
// there are and which are still pending. A design with only an event callback
// cannot express "here is the whole list, none of it has started" without smuggling
// it in as a special event kind that every implementation then has to switch on.
//
// Remediation travels alongside Detail because every error in this repository says
// what to do about itself. The alternative is for each face to re-derive an
// instruction from an error string, and they would derive different ones.
//
// Progress reports liveness, not results. What the run actually found — the
// create/update/delete counts, the merged values, the failures — comes back as the
// return value of the call, so a consumer that does not care about liveness can
// pass Discard and still get everything.
//
// Implementations must be safe for concurrent use: the units inside one stage run
// in parallel.
type Progress interface {
	// Start declares every unit the run will touch, in order, all pending.
	Start(units []string)
	// Update moves one unit, named as it was declared in Start, to a new status.
	// Detail says what happened and Remediation what to do about it; both may be
	// empty, and both are operator-facing text.
	Update(unit string, status Status, detail, remediation string)
	// Finish closes the run. failed marks the whole run as failed even when the
	// individual units look benign.
	Finish(failed bool)
}

// Discard is a Progress that drops everything, for callers that only want the
// return value.
var Discard Progress = discard{}

type discard struct{}

func (discard) Start([]string)                        {}
func (discard) Update(string, Status, string, string) {}
func (discard) Finish(bool)                           {}

// progressOr returns Discard when no Progress was configured, so every call site
// can push unconditionally.
func progressOr(progress Progress) Progress {
	if progress == nil {
		return Discard
	}
	return progress
}
