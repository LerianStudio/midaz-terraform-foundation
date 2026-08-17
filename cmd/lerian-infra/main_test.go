package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/LerianStudio/lerian-terraform-foundation/pkg/infra"
)

// fakeCheckout builds a repository shaped like lerian-terraform-foundation, with
// whatever environments.conf and backend file the test needs. Every assertion
// below stops before Terraform or AWS is reached, so none of these tests needs
// either installed.
func fakeCheckout(t *testing.T, config, backend string) string {
	t.Helper()
	root := t.TempDir()
	aws := filepath.Join(root, "examples", "aws")

	for _, dir := range []string{
		filepath.Join(aws, "bootstrap"),
		filepath.Join(aws, "infra-base", "vpc"),
		filepath.Join(aws, "infra-base", "eks"),
		filepath.Join(aws, "products", "midaz", "postgres", "envs"),
		filepath.Join(aws, "products", "midaz", "valkey", "envs"),
		filepath.Join(aws, "backend"),
		// _modules and backend are the pair resolveLayout recognises a checkout by,
		// so a fake that omits either one is not a checkout as far as the CLI is
		// concerned — which is exactly what TestRepoMustPointAtACheckout relies on.
		filepath.Join(aws, "_modules", "postgres-rds"),
	} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir: %v", err)
		}
	}
	for _, dir := range []string{
		filepath.Join(aws, "bootstrap"),
		filepath.Join(aws, "infra-base", "vpc"),
		filepath.Join(aws, "infra-base", "eks"),
		filepath.Join(aws, "products", "midaz", "postgres"),
		filepath.Join(aws, "products", "midaz", "valkey"),
	} {
		if err := os.WriteFile(filepath.Join(dir, "main.tf"), nil, 0o600); err != nil {
			t.Fatalf("write main.tf: %v", err)
		}
	}
	if config != "" {
		if err := os.WriteFile(filepath.Join(aws, "environments.conf"), []byte(config), 0o600); err != nil {
			t.Fatalf("write config: %v", err)
		}
	}
	if backend != "" {
		if err := os.WriteFile(filepath.Join(aws, "backend", "dev.hcl"), []byte(backend), 0o600); err != nil {
			t.Fatalf("write backend: %v", err)
		}
	}
	return root
}

const goodConfig = "[dev]\naccount_id = 123456789012\nprofile = lerian-dev\nregion = us-east-2\n"

func runCLI(t *testing.T, args ...string) (string, string, error) {
	t.Helper()
	stdout, stderr := &bytes.Buffer{}, &bytes.Buffer{}
	err := run(context.Background(), args, stdout, stderr)
	return stdout.String(), stderr.String(), err
}

func TestListNeedsNoEnvironmentAndNoConfiguration(t *testing.T) {
	// A checkout with no environments.conf at all: --list must still work, because
	// it is what an operator runs to find out what the flags accept.
	root := fakeCheckout(t, "", "")

	stdout, _, err := runCLI(t, "--repo", root, "--list")
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if !strings.Contains(stdout, "midaz") || !strings.Contains(stdout, "postgres valkey") {
		t.Errorf("--list output does not show the discovered product:\n%s", stdout)
	}
}

// The offline account guard, end to end: a backend file left over from another
// account is caught before Terraform is looked up and before any AWS call.
func TestWrongAccountInTheBackendFileStopsTheRun(t *testing.T) {
	root := fakeCheckout(t, goodConfig, `
bucket         = "lerian-tfstate-dev-999999999999"
region         = "us-east-2"
dynamodb_table = "lerian-tfstate-lock-dev"
`)

	_, _, err := runCLI(t, "--repo", root, "--env", "dev", "--target", "midaz", "--dry-run")
	if err == nil {
		t.Fatal("the run continued with a backend belonging to another account")
	}
	if !strings.Contains(err.Error(), "account mismatch") {
		t.Errorf("error = %q, want the account mismatch", err)
	}
}

func TestMissingEnvironmentIsExplained(t *testing.T) {
	root := fakeCheckout(t, goodConfig, "")

	_, _, err := runCLI(t, "--repo", root, "--target", "midaz")
	if err == nil {
		t.Fatal("run succeeded without --env")
	}
	for _, want := range []string{"--env is required", "dev, stg, prd"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error = %q, want it to contain %q", err, want)
		}
	}
}

// The most common typo is a product name, and it is pure filesystem work, so it
// is reported before the configuration is even opened.
func TestUnknownTargetIsReportedBeforeTheConfiguration(t *testing.T) {
	root := fakeCheckout(t, "", "")

	_, _, err := runCLI(t, "--repo", root, "--env", "dev", "--target", "ledger")
	if err == nil {
		t.Fatal("run succeeded with an unknown target")
	}
	if !strings.Contains(err.Error(), `unknown target "ledger"`) {
		t.Errorf("error = %q, want the unknown target rather than the missing config", err)
	}
}

func TestHelmValuesRefusesANonProductTarget(t *testing.T) {
	root := fakeCheckout(t, goodConfig, "")

	for _, target := range []string{"infra-base", "infra-base/vpc", "bootstrap", "all"} {
		t.Run(target, func(t *testing.T) {
			_, _, err := runCLI(t, "--repo", root, "--env", "dev",
				"--target", target, "--action", "helm-values")
			if err == nil {
				t.Fatalf("helm-values accepted %q", target)
			}
			if !strings.Contains(err.Error(), "needs a product target") {
				t.Errorf("error = %q", err)
			}
		})
	}
}

func TestDestroyRefusesBootstrap(t *testing.T) {
	root := fakeCheckout(t, goodConfig, "")

	_, _, err := runCLI(t, "--repo", root, "--env", "dev",
		"--target", "bootstrap", "--action", "destroy")
	if !errors.Is(err, infra.ErrBootstrapDestroy) {
		t.Fatalf("error = %v, want ErrBootstrapDestroy", err)
	}
}

func TestRepoMustPointAtACheckout(t *testing.T) {
	t.Setenv("LERIAN_TF_REPO", "")

	_, _, err := runCLI(t, "--repo", t.TempDir(), "--list")
	if err == nil {
		t.Fatal("run succeeded outside a checkout")
	}
	if !strings.Contains(err.Error(), "LERIAN_TF_REPO") {
		t.Errorf("error = %q, want it to name every way of pointing at the repository", err)
	}
}

// The binary lives in the repository it drives, so the ordinary invocation has no
// --repo at all: the root is found by walking up from wherever the operator
// stands, which is usually several directories deep inside a stack.
func TestRepoIsDiscoveredByWalkingUpFromTheWorkingDirectory(t *testing.T) {
	t.Setenv("LERIAN_TF_REPO", "")
	root := fakeCheckout(t, "", "")
	t.Chdir(filepath.Join(root, "examples", "aws", "products", "midaz", "postgres"))

	stdout, _, err := runCLI(t, "--list")
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if !strings.Contains(stdout, "midaz") {
		t.Errorf("--list did not resolve the checkout by walking up:\n%s", stdout)
	}
}

// A directory that holds only one of the two markers is not a checkout: the pair
// is what proves the AWS v2 layout, and half of it is what a partially-copied
// tree looks like.
func TestHalfTheMarkerIsNotACheckout(t *testing.T) {
	t.Setenv("LERIAN_TF_REPO", "")

	for _, marker := range []string{"_modules", "backend"} {
		t.Run(marker, func(t *testing.T) {
			root := t.TempDir()
			if err := os.MkdirAll(filepath.Join(root, "examples", "aws", marker), 0o755); err != nil {
				t.Fatalf("mkdir: %v", err)
			}
			if _, _, err := runCLI(t, "--repo", root, "--list"); err == nil {
				t.Fatalf("a tree holding only examples/aws/%s was accepted", marker)
			}
		})
	}
}

func TestEnvironmentVariableLocatesTheRepo(t *testing.T) {
	root := fakeCheckout(t, "", "")
	t.Setenv("LERIAN_TF_REPO", root)
	t.Chdir(t.TempDir())

	stdout, _, err := runCLI(t, "--list")
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if !strings.Contains(stdout, "midaz") {
		t.Errorf("$LERIAN_TF_REPO was not honoured:\n%s", stdout)
	}
}

// Precedence, stated once: --repo wins over $LERIAN_TF_REPO, which wins over the
// walk. The variable here points at a directory that is not a checkout, so if it
// were consulted at all the run would fail rather than quietly use the wrong one.
func TestRepoFlagBeatsTheEnvironmentVariable(t *testing.T) {
	root := fakeCheckout(t, "", "")
	t.Setenv("LERIAN_TF_REPO", t.TempDir())
	t.Chdir(t.TempDir())

	stdout, _, err := runCLI(t, "--repo", root, "--list")
	if err != nil {
		t.Fatalf("run: %v", err)
	}
	if !strings.Contains(stdout, "midaz") {
		t.Errorf("--repo did not take precedence over $LERIAN_TF_REPO:\n%s", stdout)
	}
}

func TestOutsideACheckoutTheErrorNamesEveryWayOfPointingAtOne(t *testing.T) {
	t.Setenv("LERIAN_TF_REPO", "")
	t.Chdir(t.TempDir())

	_, _, err := runCLI(t, "--list")
	if err == nil {
		t.Fatal("run succeeded outside any checkout")
	}
	for _, want := range []string{"--repo", "LERIAN_TF_REPO", "from inside the checkout"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error = %q, want it to mention %q", err, want)
		}
	}
}

func TestInvalidFlagValuesAreRejected(t *testing.T) {
	root := fakeCheckout(t, goodConfig, "")

	tests := []struct {
		name   string
		args   []string
		wantIn string
	}{
		{"action", []string{"--action", "aplly"}, "invalid action"},
		{"format", []string{"--format", "toml", "--action", "helm-values", "--target", "midaz"}, "invalid --format"},
		{"jobs", []string{"--jobs", "0"}, "invalid --jobs"},
		{"environment", []string{"--env", "prod"}, `invalid --env "prod"`},
		{"positional argument", []string{"aws"}, "unexpected argument"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			args := append([]string{"--repo", root, "--env", "dev"}, test.args...)
			_, _, err := runCLI(t, args...)
			if err == nil {
				t.Fatal("run succeeded, want an error")
			}
			if !strings.Contains(err.Error(), test.wantIn) {
				t.Errorf("error = %q, want it to contain %q", err, test.wantIn)
			}
		})
	}
}
