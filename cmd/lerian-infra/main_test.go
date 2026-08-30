package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

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
		// Not a provider name: aws/azure/gcp carry their own redirects, asserted
		// by TestProviderPositionalRedirect.
		{"positional argument", []string{"midaz"}, "unexpected argument"},
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

// deploy.sh took the provider positionally and pointed azure/gcp at the legacy
// script. Removing it did not remove that signpost, and must not: examples/gcp and
// examples/azure are still on the pre-v2 layout, and only deploy-legacy.sh reaches
// them.
func TestProviderPositionalRedirect(t *testing.T) {
	for _, tc := range []struct{ arg, want string }{
		{"gcp", "deploy-legacy.sh"},
		{"azure", "deploy-legacy.sh"},
		{"aws", "--env dev"},
	} {
		var out, errOut bytes.Buffer
		err := run(context.Background(), []string{tc.arg}, &out, &errOut)
		if err == nil {
			t.Fatalf("%s: expected an error", tc.arg)
		}
		if !strings.Contains(err.Error(), tc.want) {
			t.Errorf("%s: error should mention %q, got:\n%s", tc.arg, tc.want, err)
		}
	}
}

// checkoutTree builds a minimal directory that IsCheckout recognises.
func checkoutTree(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for _, dir := range [][]string{
		{"examples", "aws", "_modules"},
		{"examples", "aws", "backend"},
	} {
		if err := os.MkdirAll(filepath.Join(append([]string{root}, dir...)...), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

// The managed checkout is LAST on purpose. An operator inside a development
// checkout must keep driving that one: resolving to the managed tree because it
// also happens to exist would run their command against different templates than
// the ones they are editing, and nothing in the output would say so.
func TestResolveLayoutPrefersTheWorkingDirectoryOverTheManagedCheckout(t *testing.T) {
	managed := checkoutTree(t)
	working := checkoutTree(t)

	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })
	if err := os.Chdir(working); err != nil {
		t.Fatal(err)
	}

	layout, source, err := resolveLayout("", "", managed)
	if err != nil {
		t.Fatal(err)
	}
	if source != sourceWorkingIn {
		t.Errorf("source = %q, want %q", source, sourceWorkingIn)
	}
	// macOS resolves TempDir through /var -> /private/var, so compare by suffix.
	if !strings.HasSuffix(layout.Root, filepath.Base(working)) {
		t.Errorf("layout.Root = %q, want the working checkout %q", layout.Root, working)
	}
}

// With nothing named and nothing nearby, the managed checkout is the fallback —
// which is what makes a binary downloaded from the releases page usable from any
// directory.
func TestResolveLayoutFallsBackToTheManagedCheckout(t *testing.T) {
	managed := checkoutTree(t)

	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })
	// A directory that is NOT inside any checkout.
	outside := t.TempDir()
	if err := os.Chdir(outside); err != nil {
		t.Fatal(err)
	}

	layout, source, err := resolveLayout("", "", managed)
	if err != nil {
		t.Fatalf("expected the managed checkout to resolve: %v", err)
	}
	if source != sourceManaged {
		t.Errorf("source = %q, want %q", source, sourceManaged)
	}
	if !strings.HasSuffix(layout.Root, filepath.Base(managed)) {
		t.Errorf("layout.Root = %q, want %q", layout.Root, managed)
	}
}

// "Not found" without "here is where I looked" leaves the operator guessing which
// of four mechanisms they got wrong. The failure must name all four AND show the
// value each one had.
func TestResolveLayoutFailureNamesEveryPlaceItLooked(t *testing.T) {
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(previous) })
	outside := t.TempDir()
	if err := os.Chdir(outside); err != nil {
		t.Fatal(err)
	}

	_, _, err = resolveLayout("", "", filepath.Join(t.TempDir(), "absent"))
	if err == nil {
		t.Fatal("expected a failure with no checkout anywhere")
	}
	for _, want := range []string{
		"--repo", "$LERIAN_TF_REPO", "the working directory and parents",
		"the managed checkout", "init --clone",
	} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the failure must mention %q:\n%v", want, err)
		}
	}
}

// A path the operator named that is not a checkout is a different failure from
// having named nothing — and it must still list every way of pointing at one.
func TestNotACheckoutStillListsAllFourOptions(t *testing.T) {
	empty := t.TempDir()
	_, _, err := resolveLayout(empty, "", "")
	if err == nil {
		t.Fatal("an empty directory is not a checkout")
	}
	if !strings.Contains(err.Error(), "init --clone") {
		t.Errorf("the fourth option must be offered here too:\n%v", err)
	}
	if !strings.Contains(err.Error(), "--repo") {
		t.Errorf("the failure must name the source it resolved from:\n%v", err)
	}
}

// The spinner repaints, so it must run only where a repaint means something. This
// was a documented invariant every caller had to remember, and the second caller
// forgot it: piping the output produced every frame on its own line, which in a CI
// log is hundreds of lines of carriage-return debris. The constructor enforces it
// now, so no future caller can reintroduce it.
func TestSpinnerIsInertWhenTheDestinationCannotRepaint(t *testing.T) {
	var mu sync.Mutex
	out := &bytes.Buffer{}

	spin := newSpinner(&mu, out, "cloning v1.6.0")
	// Long enough that a live spinner would have painted several frames.
	time.Sleep(150 * time.Millisecond)
	spin.Stop()

	if out.Len() != 0 {
		t.Errorf("a buffer is not a terminal, so nothing should have been painted:\n%q", out.String())
	}
	// Stop must be safe, and safe twice: the inert path closes no channel.
	spin.Stop()
}
