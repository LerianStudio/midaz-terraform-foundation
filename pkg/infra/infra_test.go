package infra

import (
	"strings"
	"testing"
)

func TestParseAction(t *testing.T) {
	for _, valid := range []string{"plan", "apply", "destroy", "output", "helm-values"} {
		action, err := ParseAction(valid)
		if err != nil {
			t.Errorf("ParseAction(%q): %v", valid, err)
		}
		if string(action) != valid {
			t.Errorf("ParseAction(%q) = %q", valid, action)
		}
	}

	_, err := ParseAction("aplly")
	if err == nil {
		t.Fatal("ParseAction accepted a typo")
	}
	// The error lists what is valid, because a typo is the only way to reach it.
	if !strings.Contains(err.Error(), "helm-values") {
		t.Errorf("error = %q, want the list of valid actions", err)
	}
}

func TestValidEnvironment(t *testing.T) {
	for _, valid := range Environments {
		if !ValidEnvironment(valid) {
			t.Errorf("ValidEnvironment(%q) = false", valid)
		}
	}
	for _, invalid := range []string{"", "prod", "PRD", "staging"} {
		if ValidEnvironment(invalid) {
			t.Errorf("ValidEnvironment(%q) = true", invalid)
		}
	}
}

func TestDiscardAcceptsEveryCall(t *testing.T) {
	// Callers that only want the return value pass nil, and every call site pushes
	// unconditionally; this is what keeps that from panicking.
	progress := progressOr(nil)
	progress.Start([]string{"products/midaz/postgres"})
	progress.Update("products/midaz/postgres", StatusRunning, "detail", "remediation")
	progress.Finish(false)

	if progressOr(Discard) != Discard {
		t.Error("progressOr replaced an explicit Discard")
	}
	recorder := &recordingProgress{}
	if progressOr(recorder) != Progress(recorder) {
		t.Error("progressOr replaced a real Progress")
	}
}
