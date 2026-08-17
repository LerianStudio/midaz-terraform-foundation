package infra

import (
	"context"
	"errors"
	"os"
	"strings"
	"testing"
)

func writeBackend(t *testing.T, layout Layout, env, contents string) {
	t.Helper()
	if err := os.MkdirAll(layout.BackendDir(), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(layout.BackendFile(env), []byte(contents), 0o600); err != nil {
		t.Fatalf("write backend: %v", err)
	}
}

const devConfig = "[dev]\naccount_id = 123456789012\nprofile = lerian-dev\nregion = us-east-2\n"

func TestLoadBackendParsesTheGeneratedFile(t *testing.T) {
	layout := writeConfig(t, devConfig)
	writeBackend(t, layout, "dev", `
bucket         = "lerian-tfstate-dev-123456789012"
region         = "us-east-2"
dynamodb_table = "lerian-tfstate-lock-dev"
encrypt        = true
`)

	backend, err := LoadBackend(layout, "dev")
	if err != nil {
		t.Fatalf("LoadBackend: %v", err)
	}
	if backend.Bucket != "lerian-tfstate-dev-123456789012" {
		t.Errorf("Bucket = %q", backend.Bucket)
	}
	if backend.Region != "us-east-2" {
		t.Errorf("Region = %q", backend.Region)
	}
}

func TestLoadBackendReportsAMissingFileAsItsOwnCase(t *testing.T) {
	layout := writeConfig(t, devConfig)

	_, err := LoadBackend(layout, "dev")
	if !errors.Is(err, ErrNoBackendFile) {
		t.Fatalf("error = %v, want ErrNoBackendFile", err)
	}
	if !strings.Contains(err.Error(), "--target bootstrap") {
		t.Errorf("error = %q, want it to name the bootstrap run that generates the file", err)
	}
}

// The offline account guard. This is the check that costs nothing and catches the
// mistake that otherwise surfaces as a 403 at apply time.
func TestCheckBackendRejectsABucketFromAnotherAccount(t *testing.T) {
	layout := writeConfig(t, devConfig)
	config, err := LoadEnvConfig(layout, "dev")
	if err != nil {
		t.Fatalf("LoadEnvConfig: %v", err)
	}
	backend := Backend{
		Path:   layout.BackendFile("dev"),
		Bucket: "lerian-tfstate-dev-999999999999",
		Region: "us-east-2",
	}

	_, err = CheckBackend(layout, config, backend)
	if err == nil {
		t.Fatal("CheckBackend accepted a bucket belonging to another account")
	}
	for _, want := range []string{"123456789012", "999999999999", "stale"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error = %q, want it to contain %q", err, want)
		}
	}
}

func TestCheckBackendRejectsARegionMismatch(t *testing.T) {
	layout := writeConfig(t, devConfig)
	config, err := LoadEnvConfig(layout, "dev")
	if err != nil {
		t.Fatalf("LoadEnvConfig: %v", err)
	}
	backend := Backend{
		Path:   layout.BackendFile("dev"),
		Bucket: "lerian-tfstate-dev-123456789012",
		Region: "sa-east-1",
	}

	_, err = CheckBackend(layout, config, backend)
	if err == nil {
		t.Fatal("CheckBackend accepted a backend in another region")
	}
	if !strings.Contains(err.Error(), "region mismatch") {
		t.Errorf("error = %q, want a region mismatch", err)
	}
}

func TestCheckBackendWarnsButPassesOnAHandNamedBucket(t *testing.T) {
	layout := writeConfig(t, devConfig)
	config, err := LoadEnvConfig(layout, "dev")
	if err != nil {
		t.Fatalf("LoadEnvConfig: %v", err)
	}
	// Right account, but not the name bootstrap would have given it.
	backend := Backend{
		Path:   layout.BackendFile("dev"),
		Bucket: "acme-terraform-state-123456789012",
		Region: "us-east-2",
	}

	warnings, err := CheckBackend(layout, config, backend)
	if err != nil {
		t.Fatalf("CheckBackend: %v", err)
	}
	if len(warnings) != 1 {
		t.Fatalf("got %d warnings, want 1: %v", len(warnings), warnings)
	}
}

type stubIdentity struct {
	caller Caller
	err    error

	gotProfile string
	gotRegion  string
}

func (s *stubIdentity) CallerIdentity(_ context.Context, profile, region string) (Caller, error) {
	s.gotProfile = profile
	s.gotRegion = region
	return s.caller, s.err
}

// The online guard, and the reason this package exists. Applying prd into the dev
// account is the worst mistake available in the Terraform repository.
func TestVerifyAccountRefusesTheWrongAccount(t *testing.T) {
	config := EnvConfig{
		Environment: "prd",
		AccountID:   "345678901234",
		Region:      "us-east-1",
		Profile:     "lerian-prd",
	}
	identity := &stubIdentity{caller: Caller{
		Account: "123456789012",
		ARN:     "arn:aws:sts::123456789012:assumed-role/Developer/ferreira",
	}}

	_, err := VerifyAccount(context.Background(), identity, config)
	if !errors.Is(err, ErrWrongAccount) {
		t.Fatalf("error = %v, want ErrWrongAccount", err)
	}
	for _, want := range []string{
		"345678901234",                    // what the config declares
		"123456789012",                    // what the credentials resolve to
		"assumed-role/Developer/ferreira", // who that is
		"lerian-prd",                      // which profile was used
		"no flag to skip this",            // and that there is no way around it
	} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error is missing %q:\n%s", want, err)
		}
	}
}

func TestVerifyAccountAcceptsTheDeclaredAccount(t *testing.T) {
	config := EnvConfig{
		Environment: "dev",
		AccountID:   "123456789012",
		Region:      "us-east-2",
		Profile:     "lerian-dev",
	}
	identity := &stubIdentity{caller: Caller{
		Account: "123456789012",
		ARN:     "arn:aws:iam::123456789012:user/ci",
	}}

	caller, err := VerifyAccount(context.Background(), identity, config)
	if err != nil {
		t.Fatalf("VerifyAccount: %v", err)
	}
	if caller.ARN != "arn:aws:iam::123456789012:user/ci" {
		t.Errorf("ARN = %q", caller.ARN)
	}
	if identity.gotProfile != "lerian-dev" || identity.gotRegion != "us-east-2" {
		t.Errorf("resolved with profile %q region %q, want lerian-dev/us-east-2",
			identity.gotProfile, identity.gotRegion)
	}
}

func TestVerifyAccountExplainsAnExpiredSSOSession(t *testing.T) {
	config := EnvConfig{Environment: "dev", AccountID: "123456789012", Region: "us-east-2", Profile: "lerian-dev"}
	identity := &stubIdentity{err: errors.New("Error loading SSO Token: Token has expired")}

	_, err := VerifyAccount(context.Background(), identity, config)
	if err == nil {
		t.Fatal("VerifyAccount succeeded, want an error")
	}
	if !strings.Contains(err.Error(), "aws sso login --profile lerian-dev") {
		t.Errorf("error = %q, want the sso login instruction", err)
	}
}

func TestVerifyAccountExplainsAmbientCredentials(t *testing.T) {
	config := EnvConfig{Environment: "dev", AccountID: "123456789012", Region: "us-east-2"}
	identity := &stubIdentity{err: errors.New("Unable to locate credentials")}

	_, err := VerifyAccount(context.Background(), identity, config)
	if err == nil {
		t.Fatal("VerifyAccount succeeded, want an error")
	}
	if !strings.Contains(err.Error(), "ambient credentials") {
		t.Errorf("error = %q, want it to explain that no profile is configured", err)
	}
}

func TestLoadBackendRejectsAFileWithoutABucket(t *testing.T) {
	layout := writeConfig(t, devConfig)
	writeBackend(t, layout, "dev", "# only a comment\nencrypt = true\n")

	_, err := LoadBackend(layout, "dev")
	if err == nil {
		t.Fatal("LoadBackend accepted a file with no bucket")
	}
	if !strings.Contains(err.Error(), "lerian-tfstate-dev-<account_id>") {
		t.Errorf("error = %q, want the shape the file should have", err)
	}
}

func TestLoadBackendIgnoresCommentsAndTakesTheFirstValue(t *testing.T) {
	layout := writeConfig(t, devConfig)
	writeBackend(t, layout, "dev", `
# bucket = "lerian-tfstate-dev-000000000000"
bucket = "lerian-tfstate-dev-123456789012"
bucket = "lerian-tfstate-dev-999999999999"
region = "us-east-2"
`)

	backend, err := LoadBackend(layout, "dev")
	if err != nil {
		t.Fatalf("LoadBackend: %v", err)
	}
	if backend.Bucket != "lerian-tfstate-dev-123456789012" {
		t.Errorf("Bucket = %q, want the first uncommented value", backend.Bucket)
	}
}
