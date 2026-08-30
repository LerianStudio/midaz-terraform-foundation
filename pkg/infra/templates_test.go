package infra

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// hermeticGitEnv detaches git from the machine's own configuration.
//
// Without it the test inherits whatever the developer has set globally, and this
// one broke on a config requiring signed tags: `git tag v1.6.0` came back with
// "no tag message?". A test that passes or fails depending on the operator's
// ~/.gitconfig is testing the wrong thing.
func hermeticGitEnv() []string {
	return append(os.Environ(),
		"GIT_CONFIG_GLOBAL=/dev/null",
		"GIT_CONFIG_SYSTEM=/dev/null",
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t",
	)
}

// fakeTemplatesRepo builds a real git repository with the two marker directories
// and two tags, then returns a path that can be cloned FROM. Everything here runs
// against local git: the point is to exercise the real GitCLI without the network,
// because a mock of git would only prove the mock agrees with itself.
func fakeTemplatesRepo(t *testing.T) string {
	t.Helper()
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	dir := t.TempDir()

	run := func(args ...string) {
		t.Helper()
		command := exec.Command("git", args...)
		command.Dir = dir
		command.Env = hermeticGitEnv()
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
		}
	}

	run("init", "-q", "--initial-branch=main")
	for _, marker := range checkoutMarkers {
		if err := os.MkdirAll(filepath.Join(append([]string{dir}, marker...)...), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// git does not track directories, so each marker needs a file to survive a clone.
	for _, marker := range checkoutMarkers {
		keep := filepath.Join(append(append([]string{dir}, marker...), ".gitkeep")...)
		if err := os.WriteFile(keep, nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// The configuration this tool writes is ignored, which is what makes it survive
	// a checkout — the property SyncTemplates depends on.
	if err := os.WriteFile(filepath.Join(dir, ".gitignore"),
		[]byte("examples/aws/environments.conf\nexamples/aws/backend/*.hcl\n*.tfvars\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("add", "-A")
	run("commit", "-qm", "v1.6.0 tree")
	run("tag", "v1.6.0")

	if err := os.WriteFile(filepath.Join(dir, "NEW.md"), []byte("added in 1.7.0\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("add", "-A")
	run("commit", "-qm", "v1.7.0 tree")
	run("tag", "v1.7.0")

	return dir
}

// A managed checkout is pinned to a tag, never to a branch: the chart mapping in
// this binary and the HCL in the templates are two halves of one contract.
func TestCloneTemplatesPinsTheRequestedTag(t *testing.T) {
	source := fakeTemplatesRepo(t)
	git := GitCLI{}
	dest := filepath.Join(t.TempDir(), "terraform-foundation")

	if err := git.Clone(context.Background(), source, "v1.6.0", dest); err != nil {
		t.Fatal(err)
	}
	if !IsCheckout(dest) {
		t.Fatal("the clone should be recognised as a checkout")
	}
	state := InspectCheckout(context.Background(), git, dest, true)
	if !state.AtVersion("v1.6.0") {
		t.Errorf("state = %+v, want ref v1.6.0", state)
	}
	// The later tag's file must NOT be there: a pin that silently gives you main is
	// worse than no pin, because the version line then lies.
	if _, err := os.Stat(filepath.Join(dest, "NEW.md")); err == nil {
		t.Error("v1.6.0 must not contain a file added in v1.7.0")
	}
}

// THIS IS WHY THE MANAGED PATH CARRIES NO VERSION. environments.conf and every
// envs/*.tfvars are gitignored and live inside the checkout, so a version bump
// must not disturb them. A versioned directory would orphan the whole
// configuration on every upgrade.
func TestSyncTemplatesKeepsTheOperatorsConfiguration(t *testing.T) {
	source := fakeTemplatesRepo(t)
	git := GitCLI{}
	ctx := context.Background()
	dest := filepath.Join(t.TempDir(), "terraform-foundation")

	if err := git.Clone(ctx, source, "v1.6.0", dest); err != nil {
		t.Fatal(err)
	}

	// What init writes: ignored by the repository, precious to the operator.
	config := filepath.Join(dest, "examples", "aws", "environments.conf")
	if err := os.WriteFile(config, []byte("[dev]\naccount_id = 123456789012\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	tfvars := filepath.Join(dest, "examples", "aws", "backend", "dev.hcl")
	if err := os.WriteFile(tfvars, []byte("bucket = \"x\"\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	if err := SyncTemplates(ctx, git, dest, "v1.7.0"); err != nil {
		t.Fatalf("SyncTemplates: %v", err)
	}

	if state := InspectCheckout(ctx, git, dest, true); !state.AtVersion("v1.7.0") {
		t.Errorf("after sync: %+v, want v1.7.0", state)
	}
	if _, err := os.Stat(filepath.Join(dest, "NEW.md")); err != nil {
		t.Error("the new tag's content should be present after sync")
	}
	for _, kept := range []string{config, tfvars} {
		if _, err := os.Stat(kept); err != nil {
			t.Errorf("the operator's %s was destroyed by the sync", filepath.Base(kept))
		}
	}
}

// A checkout with edits is the operator's work. Stashing or forcing it would
// destroy something this tool was never asked to touch.
func TestSyncTemplatesRefusesModifiedTrackedFiles(t *testing.T) {
	source := fakeTemplatesRepo(t)
	git := GitCLI{}
	ctx := context.Background()
	dest := filepath.Join(t.TempDir(), "terraform-foundation")

	if err := git.Clone(ctx, source, "v1.6.0", dest); err != nil {
		t.Fatal(err)
	}
	edited := filepath.Join(dest, ".gitignore")
	if err := os.WriteFile(edited, []byte("# edited by the operator\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	err := SyncTemplates(ctx, git, dest, "v1.7.0")
	if err == nil {
		t.Fatal("a dirty checkout must not be moved")
	}
	if !strings.Contains(err.Error(), ".gitignore") {
		t.Errorf("the error must name the file it refused to move:\n%v", err)
	}
	// And it must not have moved anyway.
	if state := InspectCheckout(ctx, git, dest, true); !state.AtVersion("v1.6.0") {
		t.Errorf("refused but moved anyway: %+v", state)
	}
}

// Untracked files are the configuration, not dirt: their presence is the normal
// state of a working checkout and must never block a sync.
func TestUntrackedFilesAreNotDirt(t *testing.T) {
	source := fakeTemplatesRepo(t)
	git := GitCLI{}
	ctx := context.Background()
	dest := filepath.Join(t.TempDir(), "terraform-foundation")

	if err := git.Clone(ctx, source, "v1.6.0", dest); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "untracked-note.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	dirty, err := git.DirtyTracked(ctx, dest)
	if err != nil {
		t.Fatal(err)
	}
	if len(dirty) != 0 {
		t.Errorf("untracked files must not count as dirt: %v", dirty)
	}
}

// A checkout on a branch reports no ref, and an unknown ref must never be read as
// "matches" — that is the false assurance this mechanism exists to remove.
func TestABranchCheckoutIsNotAtAnyVersion(t *testing.T) {
	source := fakeTemplatesRepo(t)
	git := GitCLI{}
	ctx := context.Background()
	dest := filepath.Join(t.TempDir(), "terraform-foundation")

	// No ref: clone gives the default branch, whose HEAD here happens to be tagged,
	// so move off the tag deliberately.
	if err := git.Clone(ctx, source, "", dest); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dest, "extra.md"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, args := range [][]string{{"add", "-A"}, {"commit", "-qm", "past the tag"}} {
		command := exec.Command("git", args...)
		command.Dir = dest
		command.Env = hermeticGitEnv()
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("%v: %s", err, out)
		}
	}

	state := InspectCheckout(ctx, git, dest, true)
	if state.Ref != "" {
		t.Errorf("an untagged commit should report no ref, got %q", state.Ref)
	}
	if state.AtVersion("v1.7.0") {
		t.Error("an unknown ref must not be reported as matching")
	}
	if !state.Exists {
		t.Error("it is still a checkout")
	}
}

// Cloning into a non-empty directory would interleave two trees. Refuse instead.
func TestCloneRefusesANonEmptyDestination(t *testing.T) {
	source := fakeTemplatesRepo(t)
	dest := t.TempDir()
	if err := os.WriteFile(filepath.Join(dest, "in-the-way.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	err := CloneTemplates(context.Background(), GitCLI{}, dest, "v1.6.0")
	if err == nil || !strings.Contains(err.Error(), "not empty") {
		t.Errorf("expected a refusal naming the directory, got %v", err)
	}
	_ = source
}

func TestManagedCheckoutPathHonoursTheOverride(t *testing.T) {
	override := t.TempDir()
	got, err := ManagedCheckoutPath(override)
	if err != nil {
		t.Fatal(err)
	}
	if got != override {
		t.Errorf("got %q, want %q", got, override)
	}

	def, err := ManagedCheckoutPath("")
	if err != nil {
		t.Fatal(err)
	}
	// Three properties at once: not hidden, so the operator can use the checkout
	// directly; the repository's own name, so disk matches the clone URL; and no
	// version, so an upgrade does not orphan the configuration inside it.
	if !strings.HasSuffix(def, filepath.Join("lerian", "lerian-terraform-foundation")) {
		t.Errorf("default path = %q", def)
	}
	if strings.Contains(def, "/.lerian") {
		t.Errorf("the directory must not be hidden: %q", def)
	}
}

// `status --porcelain` is column-significant: the first two characters are the
// index and worktree status, so the path starts at a fixed offset and a leading
// space carries meaning. Trimming the payload before parsing shifted every offset
// by one on the first line and produced "gitignore" for ".gitignore" — in the one
// message whose entire job is to name the file the operator has to deal with.
func TestPorcelainPathKeepsTheWholeName(t *testing.T) {
	for _, test := range []struct{ line, want string }{
		{" M .gitignore", ".gitignore"},
		{" M examples/aws/infra-base/eks/main.tf", "examples/aws/infra-base/eks/main.tf"},
		{"M  staged.tf", "staged.tf"},
		{"MM both.tf", "both.tf"},
		{"R  old.tf -> new.tf", "new.tf"},
		{"A  \"quoted name.tf\"", "quoted name.tf"},
		{" M dotted/.hidden", "dotted/.hidden"},
		{"", ""},
		{" M ", ""},
	} {
		if got := porcelainPath(test.line); got != test.want {
			t.Errorf("porcelainPath(%q) = %q, want %q", test.line, got, test.want)
		}
	}
}

// The refusal has to name the file exactly, because the operator's next action is
// to open it or discard it. An almost-right name sends them looking for a file
// that does not exist.
func TestDirtyTrackedNamesFilesExactly(t *testing.T) {
	source := fakeTemplatesRepo(t)
	git := GitCLI{}
	ctx := context.Background()
	dest := filepath.Join(t.TempDir(), "terraform-foundation")
	if err := git.Clone(ctx, source, "v1.6.0", dest); err != nil {
		t.Fatal(err)
	}

	// A dotfile first, because it is the one that exposed the offset bug.
	for _, name := range []string{".gitignore", "NEW.md"} {
		path := filepath.Join(dest, name)
		if _, err := os.Stat(path); err != nil {
			continue
		}
		if err := os.WriteFile(path, []byte("edited\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	dirty, err := git.DirtyTracked(ctx, dest)
	if err != nil {
		t.Fatal(err)
	}
	found := false
	for _, name := range dirty {
		if name == ".gitignore" {
			found = true
		}
		if strings.HasPrefix(name, "M") || strings.HasPrefix(name, " ") {
			t.Errorf("status characters leaked into the path: %q", name)
		}
	}
	if !found {
		t.Errorf("expected .gitignore with its leading dot, got %v", dirty)
	}
}

// A tag that predates the AWS v2 layout clones fine and is still unusable: the tags
// up to v1.5.0 hold one directory per resource (examples/aws/eks, examples/aws/rds)
// and have no _modules or backend at all. Reporting only "does not look like a
// checkout" reads as a broken download and sends the operator to debug git, when the
// real problem is that the binary and the templates disagree about which layout
// exists.
func TestCloneReportsATagWithoutTheV2Layout(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}
	source := t.TempDir()
	run := func(args ...string) {
		t.Helper()
		command := exec.Command("git", args...)
		command.Dir = source
		command.Env = hermeticGitEnv()
		if out, err := command.CombinedOutput(); err != nil {
			t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
		}
	}
	// The v1 layout: one directory per resource, no markers.
	run("init", "-q", "--initial-branch=main")
	for _, dir := range []string{"examples/aws/eks", "examples/aws/rds"} {
		if err := os.MkdirAll(filepath.Join(source, dir), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(source, dir, "main.tf"), nil, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	run("add", "-A")
	run("commit", "-qm", "v1 layout")
	run("tag", "v1.5.0")

	t.Setenv(TemplatesRepoEnv, source)
	dest := filepath.Join(t.TempDir(), "managed")

	err := CloneTemplates(context.Background(), GitCLI{}, dest, "v1.5.0")
	if err == nil {
		t.Fatal("a tag without the v2 layout must be refused")
	}
	for _, want := range []string{"v1.5.0", "v2 layout", "--repo"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("the error must mention %q:\n%v", want, err)
		}
	}
	// The clone is a valid clone of a real tag. Deleting a directory the operator
	// just watched being created is a worse surprise than leaving it.
	if !IsCheckoutDirPresent(dest) {
		t.Error("the clone should be left in place for inspection")
	}
}

// IsCheckoutDirPresent reports whether anything was left at path.
func IsCheckoutDirPresent(path string) bool {
	entries, err := os.ReadDir(path)
	return err == nil && len(entries) > 0
}
