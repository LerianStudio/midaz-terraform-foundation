package main

import (
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// Every one of these is an error rather than a precedence rule. An operator who
// typed two contradictory flags does not know which they want, and choosing for
// them buries the confusion inside a run that then does something unasked.
func TestContradictoryTemplateFlagsAreRefused(t *testing.T) {
	for _, test := range []struct {
		name string
		opts initOptions
		want string
	}{
		{"clone and no-clone", initOptions{clone: true, noClone: true}, "--clone and --no-clone"},
		{"repo and clone", initOptions{repo: "/x", clone: true}, "--repo and --clone"},
		{"sync and repo", initOptions{sync: true, repo: "/x"}, "--sync cannot be used with --repo"},
	} {
		err := test.opts.validateTemplateFlags()
		if err == nil {
			t.Errorf("%s: expected a refusal", test.name)
			continue
		}
		if !strings.Contains(err.Error(), test.want) {
			t.Errorf("%s: error should name the conflict %q:\n%v", test.name, test.want, err)
		}
	}

	// And the ordinary combinations must stay legal.
	for _, ok := range []initOptions{
		{}, {clone: true}, {noClone: true}, {repo: "/x"}, {sync: true},
		{clone: true, autoApprove: true},
	} {
		if err := ok.validateTemplateFlags(); err != nil {
			t.Errorf("%+v should be allowed: %v", ok, err)
		}
	}
}

// --auto-approve means "skip the confirmation before writing the files I asked
// for", and CI passes it as a matter of routine. If it also authorised a clone,
// every CI run would be able to download a repository nobody asked it to fetch.
func TestAutoApproveDoesNotAuthoriseACloneOutsideATerminal(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "managed")
	out := &bytes.Buffer{}
	// A prompter that is not interactive is exactly the CI case.
	ask := &prompter{out: out, interactive: false}

	_, err := acquireTemplates(context.Background(),
		initOptions{autoApprove: true, templatesDir: dest}, ask, out)
	if err == nil {
		t.Fatal("--auto-approve must not be enough to clone")
	}
	for _, want := range []string{"--clone", "--no-clone", "--auto-approve does not imply"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the refusal must mention %q:\n%v", want, err)
		}
	}
	if _, statErr := os.Stat(dest); statErr == nil {
		t.Error("nothing should have been created")
	}
}

// --no-clone is the way to say "fail instead", and it must fail without touching
// the network or the filesystem.
func TestNoCloneFailsWithoutCreatingAnything(t *testing.T) {
	dest := filepath.Join(t.TempDir(), "managed")
	out := &bytes.Buffer{}
	ask := &prompter{out: out, interactive: true}

	_, err := acquireTemplates(context.Background(),
		initOptions{noClone: true, templatesDir: dest}, ask, out)
	if err == nil || !strings.Contains(err.Error(), "--no-clone") {
		t.Fatalf("expected a refusal naming --no-clone, got %v", err)
	}
	if _, statErr := os.Stat(dest); statErr == nil {
		t.Error("nothing should have been created")
	}
}

// A binary with no release ldflag has no tag to match. Cloning main is allowed —
// refusing would make the tool useless to whoever is developing it — but the loss
// of parity has to be stated, because it is a consequence being accepted.
func TestUntaggedBinaryClonesTheDefaultBranchAndSaysSo(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	source := localOriginRepo(t)
	dest := filepath.Join(t.TempDir(), "managed")
	out := &bytes.Buffer{}
	ask := &prompter{out: out, interactive: true}

	t.Setenv("LERIAN_TEMPLATES_REPO", source)
	if version != devVersion {
		t.Skipf("this test describes the untagged build; version is %q", version)
	}

	layout, err := acquireTemplates(context.Background(),
		initOptions{clone: true, templatesDir: dest}, ask, out)
	if err != nil {
		t.Fatalf("acquireTemplates: %v", err)
	}
	printed := out.String()
	if !strings.Contains(printed, "parity is NOT guaranteed") {
		t.Errorf("the loss of parity must be stated:\n%s", printed)
	}
	if layout.Root == "" {
		t.Error("a layout should have been returned")
	}
}

// A mirror is an ordinary BYOC situation: an air-gapped client, or an organisation
// that vendors the templates into its own git server. Without the override the
// managed checkout would be unavailable to exactly those clients.
func TestTemplatesRepoOverrideIsHonoured(t *testing.T) {
	t.Setenv("LERIAN_TEMPLATES_REPO", "https://git.internal/mirror.git")
	if got := templatesRepoForTest(); got != "https://git.internal/mirror.git" {
		t.Errorf("override ignored: %q", got)
	}
	t.Setenv("LERIAN_TEMPLATES_REPO", "   ")
	if got := templatesRepoForTest(); !strings.Contains(got, "github.com/LerianStudio") {
		t.Errorf("blank override should fall back to the default: %q", got)
	}
}

// localOriginRepo builds a git repository that looks like the templates and can be
// cloned FROM, so none of these tests touch the network.
func localOriginRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		command := exec.Command("git", args...)
		command.Dir = dir
		command.Env = append(os.Environ(),
			"GIT_CONFIG_GLOBAL=/dev/null", "GIT_CONFIG_SYSTEM=/dev/null",
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
		}
	}
	run("init", "-q", "--initial-branch=main")
	for _, marker := range [][]string{
		{"examples", "aws", "_modules"}, {"examples", "aws", "backend"},
	} {
		full := filepath.Join(append([]string{dir}, marker...)...)
		if err := os.MkdirAll(full, 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(full, ".gitkeep"), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run("add", "-A")
	run("commit", "-qm", "templates")
	run("tag", "v1.6.0")
	return dir
}
