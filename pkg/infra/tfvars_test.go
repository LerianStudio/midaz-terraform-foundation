package infra

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func unitWithEnvs(t *testing.T, files map[string]string) Unit {
	t.Helper()
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "envs"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	for name, contents := range files {
		if err := os.WriteFile(filepath.Join(dir, "envs", name), []byte(contents), 0o600); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	return Unit{Dir: dir, Name: "products/midaz/postgres"}
}

func TestCheckReadinessAcceptsACompleteVarFile(t *testing.T) {
	unit := unitWithEnvs(t, map[string]string{
		"dev.tfvars": "environment = \"dev\"\ninstance_class = \"db.t4g.medium\"\n",
	})

	report := CheckReadiness([]Unit{unit}, "dev")
	if len(report) != 1 {
		t.Fatalf("got %d entries, want 1", len(report))
	}
	if !report[0].Ready() {
		t.Errorf("not ready: %s", report[0].Problem)
	}
}

func TestCheckReadinessPointsAtTheTemplateWhenTheVarFileIsMissing(t *testing.T) {
	unit := unitWithEnvs(t, map[string]string{
		"dev.tfvars-example": "environment = \"dev\"\n",
	})

	report := CheckReadiness([]Unit{unit}, "dev")
	if report[0].Ready() {
		t.Fatal("a missing dev.tfvars was reported as ready")
	}
	if !strings.Contains(report[0].Remediation, "cp ") {
		t.Errorf("remediation = %q, want the copy command", report[0].Remediation)
	}
}

func TestCheckReadinessSaysSoWhenThereIsNoTemplateEither(t *testing.T) {
	unit := unitWithEnvs(t, map[string]string{"stg.tfvars": "environment = \"stg\"\n"})

	report := CheckReadiness([]Unit{unit}, "prd")
	if report[0].Ready() {
		t.Fatal("reported ready with no prd.tfvars at all")
	}
	if !strings.Contains(report[0].Problem, "no prd.tfvars-example") {
		t.Errorf("problem = %q, want it to say the stack may not support prd", report[0].Problem)
	}
}

func TestCheckReadinessFindsUnresolvedPlaceholders(t *testing.T) {
	unit := unitWithEnvs(t, map[string]string{
		"dev.tfvars": `
# The comment below is prose and must not count: templates legitimately write
# things like <that address> in their explanations.
environment    = "dev"
vpc_id         = "<PUT-YOUR-VPC-ID>"
master_password_arn = "<CHANGE-ME>"
instance_class = "db.t4g.medium"
`,
	})

	report := CheckReadiness([]Unit{unit}, "dev")
	if report[0].Ready() {
		t.Fatal("a file full of placeholders was reported as ready")
	}
	if !strings.Contains(report[0].Problem, "2 line(s)") {
		t.Errorf("problem = %q, want exactly the two non-comment placeholder lines", report[0].Problem)
	}
	// Naming the lines is what turns the report into something to act on.
	if !strings.Contains(report[0].Remediation, "vpc_id") {
		t.Errorf("remediation = %q, want the offending lines", report[0].Remediation)
	}
}

func TestCheckReadinessReportsEveryUnitRatherThanTheFirstProblem(t *testing.T) {
	ready := unitWithEnvs(t, map[string]string{"dev.tfvars": "environment = \"dev\"\n"})
	missing := unitWithEnvs(t, map[string]string{})
	missing.Name = "products/midaz/valkey"

	report := CheckReadiness([]Unit{missing, ready}, "dev")
	if len(report) != 2 {
		t.Fatalf("got %d entries, want one per unit", len(report))
	}
	if report[0].Ready() || !report[1].Ready() {
		t.Errorf("report = %+v, want the order preserved and only the first not ready", report)
	}
}
