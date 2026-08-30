package main

import (
	"bytes"
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/LerianStudio/lerian-terraform-foundation/pkg/infra"
)

// initCheckout builds a repository with committed examples and no real config,
// which is what a client's first clone looks like.
func initCheckout(t *testing.T) string {
	t.Helper()
	root := t.TempDir()

	mkExample := func(dir, env, body string) {
		full := filepath.Join(root, "examples", "aws", dir, "envs")
		if err := os.MkdirAll(full, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(full, env+".tfvars-example"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		main := filepath.Join(root, "examples", "aws", dir, "main.tf")
		if err := os.WriteFile(main, []byte("# root\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.MkdirAll(filepath.Join(root, "examples", "aws", "_modules"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(filepath.Join(root, "examples", "aws", "backend"), 0o755); err != nil {
		t.Fatal(err)
	}
	mkExample("infra-base/vpc", "dev", "cidr = \"10.50.0.0/16\"\n")
	mkExample("infra-base/eks", "dev", "cidrs = [\"<PUT-YOUR-EGRESS-IP-HERE>/32\"]\n")
	mkExample("products/midaz/valkey", "dev", "node_type = \"cache.t4g.micro\"\n")
	return root
}

// Outside a terminal, a missing decision must name the flag rather than default.
// The environment is the one value with no safe default: it decides which account
// the guard will demand.
func TestInitWithoutTerminalRequiresEnv(t *testing.T) {
	root := initCheckout(t)
	var out, errOut bytes.Buffer

	err := runInit(context.Background(),
		[]string{"--repo", root}, &out, &errOut)
	if err == nil {
		t.Fatal("expected an error")
	}
	if !strings.Contains(err.Error(), "--env is required") {
		t.Errorf("error should name --env, got: %v", err)
	}
}

func TestInitWritesConfigAndVarFiles(t *testing.T) {
	root := initCheckout(t)
	var out, errOut bytes.Buffer

	// --account avoids any STS call, which is what lets this run in CI.
	err := runInit(context.Background(), []string{
		"--repo", root,
		"--env", "dev",
		"--profile", "acme",
		"--account", "123456789012",
		"--region", "us-east-2",
		"--targets", "infra-base,midaz",
		"--api-cidr", "203.0.113.7",
		"--auto-approve",
	}, &out, &errOut)
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}

	config, err := os.ReadFile(filepath.Join(root, "examples", "aws", "environments.conf"))
	if err != nil {
		t.Fatal(err)
	}
	for _, want := range []string{"[dev]", "123456789012", "acme", "us-east-2"} {
		if !strings.Contains(string(config), want) {
			t.Errorf("environments.conf missing %q:\n%s", want, config)
		}
	}

	eks, err := os.ReadFile(filepath.Join(root, "examples", "aws", "infra-base", "eks", "envs", "dev.tfvars"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(eks), "203.0.113.7/32") {
		t.Errorf("the egress placeholder was not filled:\n%s", eks)
	}

	// The product named in --targets must be materialised too, not just infra-base.
	if _, err := os.Stat(filepath.Join(root, "examples", "aws", "products", "midaz", "valkey", "envs", "dev.tfvars")); err != nil {
		t.Errorf("the product's tfvars was not written: %v", err)
	}
}

func TestInitIsIdempotentAndRefusesToClobber(t *testing.T) {
	root := initCheckout(t)
	args := []string{
		"--repo", root, "--env", "dev", "--profile", "acme",
		"--account", "123456789012", "--region", "us-east-2",
		"--targets", "infra-base", "--api-cidr", "203.0.113.7", "--auto-approve",
	}

	var out, errOut bytes.Buffer
	if err := runInit(context.Background(), args, &out, &errOut); err != nil {
		t.Fatalf("first run: %v", err)
	}

	out.Reset()
	if err := runInit(context.Background(), args, &out, &errOut); err != nil {
		t.Fatalf("re-running with the same inputs must be safe: %v", err)
	}
	if !strings.Contains(out.String(), "nothing to do") {
		t.Errorf("second run should be a no-op, got:\n%s", out.String())
	}

	// Pointing the same environment at a different account is the dangerous edit.
	moved := append([]string{}, args...)
	for i, a := range moved {
		if a == "123456789012" {
			moved[i] = "210987654321"
		}
	}
	out.Reset()
	err := runInit(context.Background(), moved, &out, &errOut)
	if err == nil {
		t.Fatal("repointing an environment at another account must not be silent")
	}
	if !strings.Contains(err.Error(), "--force") {
		t.Errorf("the error should say how to proceed deliberately, got: %v", err)
	}
	config, _ := os.ReadFile(filepath.Join(root, "examples", "aws", "environments.conf"))
	if strings.Contains(string(config), "210987654321") {
		t.Error("a refused write must leave the file untouched")
	}
}

func TestInitDryRunWritesNothing(t *testing.T) {
	root := initCheckout(t)
	var out, errOut bytes.Buffer

	err := runInit(context.Background(), []string{
		"--repo", root, "--env", "dev", "--profile", "acme",
		"--account", "123456789012", "--region", "us-east-2",
		"--targets", "infra-base", "--api-cidr", "203.0.113.7", "--dry-run",
	}, &out, &errOut)
	if err != nil {
		t.Fatalf("init: %v", err)
	}
	if !strings.Contains(out.String(), "dry run") {
		t.Errorf("output should say it wrote nothing:\n%s", out.String())
	}
	if _, err := os.Stat(filepath.Join(root, "examples", "aws", "environments.conf")); !os.IsNotExist(err) {
		t.Error("dry run wrote environments.conf")
	}
}

// A declared account that the credentials do not reach must stop here, not at
// apply time: writing it would produce a config whose own guard rejects every run.
func TestInitRejectsAccountMismatch(t *testing.T) {
	root := initCheckout(t)
	var out, errOut bytes.Buffer

	err := runInit(context.Background(), []string{
		"--repo", root, "--env", "dev",
		"--account", "12345",
		"--region", "us-east-2", "--targets", "infra-base",
		"--api-cidr", "203.0.113.7", "--auto-approve",
	}, &out, &errOut)
	if err == nil {
		t.Fatal("a malformed account id must be rejected")
	}
}

func TestInitSetFillsArbitraryPlaceholder(t *testing.T) {
	root := initCheckout(t)
	// A token this build has no special knowledge of.
	dir := filepath.Join(root, "examples", "aws", "products", "midaz", "valkey", "envs")
	if err := os.WriteFile(filepath.Join(dir, "dev.tfvars-example"),
		[]byte("name = \"<PUT-YOUR-CLUSTER-NAME-HERE>\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var out, errOut bytes.Buffer
	err := runInit(context.Background(), []string{
		"--repo", root, "--env", "dev", "--profile", "acme",
		"--account", "123456789012", "--region", "us-east-2",
		"--targets", "midaz",
		"--set", "<PUT-YOUR-CLUSTER-NAME-HERE>=midaz-dev",
		"--auto-approve",
	}, &out, &errOut)
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	written, err := os.ReadFile(filepath.Join(dir, "dev.tfvars"))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(written), "midaz-dev") {
		t.Errorf("--set did not fill the token:\n%s", written)
	}
}

// Mixing dedicated and shared inside one product is out of scope for now, so the
// mode is one decision for the whole target rather than one per datastore.
func TestInitAppliesOneModeToEveryDatastore(t *testing.T) {
	root := initCheckout(t)
	// Two datastores under one product, both carrying the switch, plus the tier
	// roots they resolve in shared mode.
	for _, name := range []string{"valkey", "postgres"} {
		td := filepath.Join(root, "examples", "aws", "products", "shared-resources", name)
		if err := os.MkdirAll(filepath.Join(td, "envs"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(td, "envs", "dev.tfvars-example"), []byte("size = 1\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(td, "main.tf"), []byte("# root\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		dir := filepath.Join(root, "examples", "aws", "products", "midaz", name, "envs")
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "dev.tfvars-example"),
			[]byte("mode = \"dedicated\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(root, "examples", "aws", "products", "midaz", name, "main.tf"),
			[]byte("# root\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	var out, errOut bytes.Buffer
	err := runInit(context.Background(), []string{
		"--repo", root, "--env", "dev", "--profile", "acme",
		"--account", "123456789012", "--region", "us-east-2",
		"--targets", "midaz", "--mode", "shared", "--auto-approve",
	}, &out, &errOut)
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}

	for _, name := range []string{"valkey", "postgres"} {
		path := filepath.Join(root, "examples", "aws", "products", "midaz", name, "envs", "dev.tfvars")
		content, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(string(content), `mode = "shared"`) {
			t.Errorf("%s was not switched to shared:\n%s", name, content)
		}
	}

	// Shared mode creates nothing and resolves a tier that no product target
	// applies. Saying so here is the difference between a clear instruction and a
	// bare "not found" from a data source ten minutes later.
	if !strings.Contains(out.String(), "shared-resources/valkey") {
		t.Errorf("the notice should name the tier to apply first:\n%s", out.String())
	}
}

func TestInitRejectsUnknownMode(t *testing.T) {
	root := initCheckout(t)
	var out, errOut bytes.Buffer

	err := runInit(context.Background(), []string{
		"--repo", root, "--env", "dev", "--profile", "acme",
		"--account", "123456789012", "--region", "us-east-2",
		"--targets", "infra-base", "--api-cidr", "203.0.113.7",
		"--mode", "hybrid", "--auto-approve",
	}, &out, &errOut)
	if err == nil {
		t.Fatal("an unknown mode must be refused")
	}
	if !strings.Contains(err.Error(), "dedicated") {
		t.Errorf("the error should list valid values, got: %v", err)
	}
}

// init must configure bootstrap even when nobody named it. It is the first command
// anybody runs, and leaving it out made the golden path — init, then bootstrap —
// fail on its second step with a missing tfvars this tool had just had the chance
// to write.
func TestInitAlsoConfiguresBootstrap(t *testing.T) {
	root := initCheckout(t)
	dir := filepath.Join(root, "examples", "aws", "bootstrap", "envs")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "dev.tfvars-example"),
		[]byte("environment = \"dev\"\nregion = \"us-east-1\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	var out, errOut bytes.Buffer
	err := runInit(context.Background(), []string{
		"--repo", root, "--env", "dev", "--profile", "acme",
		"--account", "123456789012", "--region", "us-east-2",
		"--targets", "infra-base", "--api-cidr", "203.0.113.7", "--auto-approve",
	}, &out, &errOut)
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}

	written, err := os.ReadFile(filepath.Join(dir, "dev.tfvars"))
	if err != nil {
		t.Fatalf("bootstrap tfvars was not written: %v", err)
	}
	// The region retarget has to reach it too, or bootstrap creates the state bucket
	// in a different region from everything else.
	if !strings.Contains(string(written), `region = "us-east-2"`) {
		t.Errorf("bootstrap tfvars was not retargeted:\n%s", written)
	}
}

// The shared tier holds datastores. The VPC and the cluster are foundation and are
// shared by definition, so naming "shared-resources/vpc" pointed the operator at a
// root that does not exist.
func TestSharedTierNoticeListsOnlyProductEngines(t *testing.T) {
	root := initCheckout(t)
	for _, name := range []string{"valkey", "postgres"} {
		for _, product := range []string{"midaz", "shared-resources"} {
			dir := filepath.Join(root, "examples", "aws", "products", product, name, "envs")
			if err := os.MkdirAll(dir, 0o755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(dir, "dev.tfvars-example"),
				[]byte("mode = \"dedicated\"\n"), 0o644); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(filepath.Join(root, "examples", "aws", "products", product, name, "main.tf"),
				[]byte("# root\n"), 0o644); err != nil {
				t.Fatal(err)
			}
		}
	}

	var out, errOut bytes.Buffer
	err := runInit(context.Background(), []string{
		"--repo", root, "--env", "dev", "--profile", "acme",
		"--account", "123456789012", "--region", "us-east-2",
		"--targets", "infra-base,midaz", "--mode", "shared",
		"--api-cidr", "203.0.113.7", "--auto-approve",
	}, &out, &errOut)
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}

	got := out.String()
	for _, want := range []string{"shared-resources/valkey", "shared-resources/postgres"} {
		if !strings.Contains(got, want) {
			t.Errorf("notice should name %s:\n%s", want, got)
		}
	}
	for _, forbidden := range []string{"shared-resources/vpc", "shared-resources/eks"} {
		if strings.Contains(got, forbidden) {
			t.Errorf("%s does not exist and must not be suggested:\n%s", forbidden, got)
		}
	}
}

// Shared mode makes the products resolve a tier they do not create. Configuring
// them without configuring that tier left a checkout that could not be applied,
// and made the operator run init twice to discover it.
func TestInitConfiguresTheSharedTierWithTheProducts(t *testing.T) {
	root := initCheckout(t)

	mk := func(product, service, body string) {
		dir := filepath.Join(root, "examples", "aws", "products", product, service)
		if err := os.MkdirAll(filepath.Join(dir, "envs"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "envs", "dev.tfvars-example"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "main.tf"), []byte("# root\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mk("midaz", "valkey", "mode = \"dedicated\"\n")
	// The tier root owns the instance, so it has no mode of its own.
	mk("shared-resources", "valkey", "node_type = \"cache.t4g.micro\"\n")
	// An engine the product does not use must not be dragged in.
	mk("shared-resources", "msk", "brokers = 3\n")

	var out, errOut bytes.Buffer
	err := runInit(context.Background(), []string{
		"--repo", root, "--env", "dev", "--profile", "acme",
		"--account", "123456789012", "--region", "us-east-2",
		"--targets", "midaz", "--mode", "shared", "--auto-approve",
	}, &out, &errOut)
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}

	tier := filepath.Join(root, "examples", "aws", "products", "shared-resources", "valkey", "envs", "dev.tfvars")
	written, err := os.ReadFile(tier)
	if err != nil {
		t.Fatalf("the tier the products point at was not configured: %v", err)
	}
	// Writing mode here would set a variable the tier root does not declare.
	if strings.Contains(string(written), "mode =") {
		t.Errorf("the tier owns its instance and has no mode to choose:\n%s", written)
	}

	msk := filepath.Join(root, "examples", "aws", "products", "shared-resources", "msk", "envs", "dev.tfvars")
	if _, err := os.Stat(msk); err == nil {
		t.Error("an engine no chosen product uses must not be configured")
	}

	// Applying the tier stays explicit: it is a blast radius, not a side effect.
	if !strings.Contains(out.String(), "shared-resources/valkey --action apply") {
		t.Errorf("the notice must name the apply command:\n%s", out.String())
	}
}

// Dedicated mode must not pull the tier in at all.
func TestInitLeavesTheSharedTierAloneWhenDedicated(t *testing.T) {
	root := initCheckout(t)
	for _, p := range [][2]string{{"midaz", "valkey"}, {"shared-resources", "valkey"}} {
		dir := filepath.Join(root, "examples", "aws", "products", p[0], p[1])
		if err := os.MkdirAll(filepath.Join(dir, "envs"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "envs", "dev.tfvars-example"),
			[]byte("mode = \"dedicated\"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "main.tf"), []byte("# root\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	var out, errOut bytes.Buffer
	if err := runInit(context.Background(), []string{
		"--repo", root, "--env", "dev", "--profile", "acme",
		"--account", "123456789012", "--region", "us-east-2",
		"--targets", "midaz", "--mode", "dedicated", "--auto-approve",
	}, &out, &errOut); err != nil {
		t.Fatalf("init: %v", err)
	}

	tier := filepath.Join(root, "examples", "aws", "products", "shared-resources", "valkey", "envs", "dev.tfvars")
	if _, err := os.Stat(tier); err == nil {
		t.Error("dedicated products own their datastores; the tier must not be configured")
	}
}

// A root with no mode switch is not reached by shared mode, and the s3 roots are
// exactly that: a bucket is never shared between products, so the tier has no s3
// root and the product's own root still creates one. The no-op was correct and
// silent, which left the table claiming the root "creates nothing" while it was
// about to create a bucket.
func TestSharedModeNamesTheRootsItDoesNotReach(t *testing.T) {
	root := initCheckout(t)

	mk := func(product, service, body string) {
		dir := filepath.Join(root, "examples", "aws", "products", product, service)
		if err := os.MkdirAll(filepath.Join(dir, "envs"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "envs", "dev.tfvars-example"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "main.tf"), []byte("# root\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	mk("reporter", "valkey", "mode = \"dedicated\"\n")
	// No mode line, and deliberately so: this is what an s3 root looks like.
	mk("reporter", "s3", "bucket_suffix = \"objects\"\n")
	mk("shared-resources", "valkey", "node_type = \"cache.t4g.micro\"\n")

	var out, errOut bytes.Buffer
	err := runInit(context.Background(), []string{
		"--repo", root, "--env", "dev", "--profile", "acme",
		"--account", "123456789012", "--region", "us-east-2",
		"--targets", "reporter", "--mode", "shared", "--auto-approve",
	}, &out, &errOut)
	if err != nil {
		t.Fatalf("init: %v\n%s", err, out.String())
	}
	got := out.String()

	if !strings.Contains(got, "products/reporter/s3") {
		t.Errorf("the notice must name the root shared mode did not reach:\n%s", got)
	}
	if !strings.Contains(got, "creates its own, not shareable") {
		t.Errorf("the s3 row must not be described as creating nothing:\n%s", got)
	}

	// The switch must be absent from the written file, not set to dedicated: adding
	// a mode line to a root that has no mode variable would fail at plan time.
	written, err := os.ReadFile(filepath.Join(
		root, "examples", "aws", "products", "reporter", "s3", "envs", "dev.tfvars"))
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(written), "mode") {
		t.Errorf("shared mode must not inject a mode switch into an s3 root:\n%s", written)
	}
}

// The switch is a property of the template, so it is read from the example: the
// real tfvars may not exist yet when the question is asked.
func TestSupportsModeReadsTheExample(t *testing.T) {
	root := initCheckout(t)

	mk := func(service, body string) infra.Unit {
		dir := filepath.Join(root, "examples", "aws", "products", "reporter", service)
		if err := os.MkdirAll(filepath.Join(dir, "envs"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, "envs", "dev.tfvars-example"), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return infra.Unit{Name: "products/reporter/" + service, Dir: dir}
	}

	cases := []struct {
		service string
		body    string
		want    bool
	}{
		{"valkey", "mode = \"dedicated\"\n", true},
		{"s3", "bucket_suffix = \"objects\"\n", false},
		// The switch must not be seen in a comment explaining it, nor in a variable
		// that merely ends in "mode" — valkey carries transit_encryption_mode.
		{"documentdb", "# mode = \"shared\" would resolve the tier\ntransit_encryption_mode = \"preferred\"\n", false},
	}
	for _, tc := range cases {
		unit := mk(tc.service, tc.body)
		got, err := infra.SupportsMode(unit, "dev")
		if err != nil {
			t.Fatalf("%s: %v", tc.service, err)
		}
		if got != tc.want {
			t.Errorf("SupportsMode(%s) = %v, want %v", tc.service, got, tc.want)
		}
	}
}
