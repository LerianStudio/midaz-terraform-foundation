package infra

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// writeConfig lays out a checkout with just enough of examples/aws to be read.
func writeConfig(t *testing.T, contents string) Layout {
	t.Helper()
	root := t.TempDir()
	layout, err := NewLayout(root)
	if err != nil {
		t.Fatalf("NewLayout: %v", err)
	}
	if err := os.MkdirAll(layout.AWSDir(), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if contents != "" {
		if err := os.WriteFile(layout.ConfigFile(), []byte(contents), 0o600); err != nil {
			t.Fatalf("write config: %v", err)
		}
	}
	return layout
}

func TestLoadEnvConfigReadsASection(t *testing.T) {
	layout := writeConfig(t, `
# a comment
[dev]
account_id = 123456789012
profile    = lerian-dev     # trailing comment
region     = us-east-2

[prd]
account_id = 345678901234
profile    =
region     = us-east-1
`)

	dev, err := LoadEnvConfig(layout, "dev")
	if err != nil {
		t.Fatalf("LoadEnvConfig(dev): %v", err)
	}
	if dev.AccountID != "123456789012" {
		t.Errorf("AccountID = %q, want 123456789012", dev.AccountID)
	}
	if dev.Profile != "lerian-dev" {
		t.Errorf("Profile = %q, want lerian-dev (the trailing comment must be stripped)", dev.Profile)
	}
	if dev.Region != "us-east-2" {
		t.Errorf("Region = %q, want us-east-2", dev.Region)
	}

	prd, err := LoadEnvConfig(layout, "prd")
	if err != nil {
		t.Fatalf("LoadEnvConfig(prd): %v", err)
	}
	if prd.Profile != "" {
		t.Errorf("Profile = %q, want empty: an empty profile is the CI shape", prd.Profile)
	}
}

func TestLoadEnvConfigSupportsOneAccountForEveryEnvironment(t *testing.T) {
	// Documented and supported: resource names carry the environment and state is
	// segregated by bucket, so nothing collides.
	layout := writeConfig(t, `
[dev]
account_id = 123456789012
profile    = lerian
region     = us-east-2
[stg]
account_id = 123456789012
profile    = lerian
region     = us-east-2
[prd]
account_id = 123456789012
profile    = lerian
region     = us-east-2
`)

	for _, env := range Environments {
		config, err := LoadEnvConfig(layout, env)
		if err != nil {
			t.Fatalf("LoadEnvConfig(%s): %v", env, err)
		}
		if config.AccountID != "123456789012" {
			t.Errorf("%s: AccountID = %q, want 123456789012", env, config.AccountID)
		}
	}
}

func TestLoadEnvConfigTreatsADashProfileAsAmbientCredentials(t *testing.T) {
	layout := writeConfig(t, "[dev]\naccount_id = 123456789012\nprofile = -\nregion = us-east-2\n")

	config, err := LoadEnvConfig(layout, "dev")
	if err != nil {
		t.Fatalf("LoadEnvConfig: %v", err)
	}
	if config.Profile != "" {
		t.Errorf("Profile = %q, want empty", config.Profile)
	}
}

func TestLoadEnvConfigRejectsBadInput(t *testing.T) {
	tests := []struct {
		name     string
		contents string
		env      string
		wantIn   string
	}{
		{
			name:     "no section for the environment",
			contents: "[dev]\naccount_id = 123456789012\nregion = us-east-2\n",
			env:      "prd",
			wantIn:   "no [prd] section",
		},
		{
			name:     "no account_id",
			contents: "[dev]\nregion = us-east-2\n",
			env:      "dev",
			wantIn:   "has no account_id",
		},
		{
			name:     "account_id is not twelve digits",
			contents: "[dev]\naccount_id = 12345\nregion = us-east-2\n",
			env:      "dev",
			wantIn:   "exactly 12 digits",
		},
		{
			name:     "account_id carries a dash",
			contents: "[dev]\naccount_id = 1234-5678-901\nregion = us-east-2\n",
			env:      "dev",
			wantIn:   "exactly 12 digits",
		},
		{
			name:     "no region",
			contents: "[dev]\naccount_id = 123456789012\n",
			env:      "dev",
			wantIn:   "has no region",
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			layout := writeConfig(t, test.contents)
			_, err := LoadEnvConfig(layout, test.env)
			if err == nil {
				t.Fatal("LoadEnvConfig succeeded, want an error")
			}
			if !strings.Contains(err.Error(), test.wantIn) {
				t.Errorf("error = %q, want it to contain %q", err, test.wantIn)
			}
		})
	}
}

func TestLoadEnvConfigReportsAMissingFileAsItsOwnCase(t *testing.T) {
	layout := writeConfig(t, "")

	_, err := LoadEnvConfig(layout, "dev")
	if !errors.Is(err, ErrNoConfigFile) {
		t.Fatalf("error = %v, want ErrNoConfigFile", err)
	}
	// The instruction has to name the copy to make, because this is the first
	// thing a fresh clone hits.
	if !strings.Contains(err.Error(), filepath.Base(layout.ConfigExample())) {
		t.Errorf("error = %q, want it to point at %s", err, layout.ConfigExample())
	}
}
