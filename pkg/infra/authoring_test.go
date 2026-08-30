package infra

import (
	"context"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// awsHome builds a fake ~/.aws with the two files ListAWSProfiles reads.
func awsHome(t *testing.T, config, credentials string) string {
	t.Helper()
	dir := t.TempDir()
	if config != "" {
		if err := os.WriteFile(filepath.Join(dir, "config"), []byte(config), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if credentials != "" {
		if err := os.WriteFile(filepath.Join(dir, "credentials"), []byte(credentials), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestListAWSProfiles(t *testing.T) {
	dir := awsHome(t,
		// "[profile x]" in config, bare "[default]", plus a section that is neither
		// and must not become a profile.
		"[profile lerian-dev]\nregion = us-east-2\n\n"+
			"[default]\nregion = us-east-1\n\n"+
			"[sso-session lerian]\nsso_start_url = https://example.awsapps.com/start\n",
		// Bare sections in credentials; lerian-dev repeats and must not lose its region.
		"[ci-user]\naws_access_key_id = AKIAEXAMPLE\n\n[lerian-dev]\n",
	)

	profiles, err := listAWSProfilesIn(dir)
	if err != nil {
		t.Fatal(err)
	}

	got := map[string]AWSProfile{}
	for _, profile := range profiles {
		got[profile.Name] = profile
	}
	for _, name := range []string{"lerian-dev", "default", "ci-user"} {
		if _, ok := got[name]; !ok {
			t.Errorf("expected profile %q, got %v", name, profiles)
		}
	}
	if _, ok := got["sso-session lerian"]; ok {
		t.Error("an sso-session section must not be listed as a profile")
	}
	// config carries the region and must win over the bare credentials entry.
	if got["lerian-dev"].Region != "us-east-2" {
		t.Errorf("lerian-dev region = %q, want us-east-2", got["lerian-dev"].Region)
	}
	if got["lerian-dev"].Source != "config" {
		t.Errorf("lerian-dev source = %q, want config", got["lerian-dev"].Source)
	}
}

func TestListAWSProfilesMissingFilesIsNotAnError(t *testing.T) {
	// A CI machine with only environment credentials has neither file. That shape
	// is supported by this repository, so it must not fail here.
	profiles, err := listAWSProfilesIn(t.TempDir())
	if err != nil {
		t.Fatalf("missing AWS config should not be an error: %v", err)
	}
	if len(profiles) != 0 {
		t.Errorf("expected no profiles, got %v", profiles)
	}
}

// perProfileIdentity answers per profile name, so one dead profile can be tested next to
// a healthy one.
type perProfileIdentity struct {
	accounts map[string]string
	errs     map[string]error
}

func (s perProfileIdentity) CallerIdentity(_ context.Context, profile, _ string) (Caller, error) {
	if err, ok := s.errs[profile]; ok {
		return Caller{}, err
	}
	return Caller{Account: s.accounts[profile], ARN: "arn:aws:sts::" + s.accounts[profile] + ":assumed-role/x"}, nil
}

func TestResolveProfilesKeepsOrderAndIsolatesFailures(t *testing.T) {
	identity := perProfileIdentity{
		accounts: map[string]string{"good": "123456789012", "other": "210987654321"},
		errs:     map[string]error{"expired": errors.New("SSO session expired")},
	}
	profiles := []AWSProfile{{Name: "good"}, {Name: "expired"}, {Name: "other"}}

	resolved := ResolveProfiles(context.Background(), identity, profiles, "us-east-2")

	if len(resolved) != 3 {
		t.Fatalf("expected 3 results, got %d", len(resolved))
	}
	// Order must follow the input, not completion: the table shown to an operator
	// has to be stable across runs.
	for i, want := range []string{"good", "expired", "other"} {
		if resolved[i].Profile.Name != want {
			t.Errorf("position %d = %q, want %q", i, resolved[i].Profile.Name, want)
		}
	}
	if !resolved[0].Usable() || resolved[0].Caller.Account != "123456789012" {
		t.Errorf("good should resolve: %+v", resolved[0])
	}
	// One broken profile must not hide the working ones.
	if resolved[1].Usable() {
		t.Error("expired profile must not be usable")
	}
	if !resolved[2].Usable() {
		t.Error("a failure in the middle must not affect later profiles")
	}
}

type stubDoer func(*http.Request) (*http.Response, error)

func (f stubDoer) Do(r *http.Request) (*http.Response, error) { return f(r) }

func response(status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Status:     http.StatusText(status),
		Body:       io.NopCloser(strings.NewReader(body)),
	}
}

func TestDetectEgressIP(t *testing.T) {
	// The service answers with a trailing newline.
	ip, err := DetectEgressIP(context.Background(),
		stubDoer(func(*http.Request) (*http.Response, error) { return response(200, "203.0.113.7\n"), nil }))
	if err != nil {
		t.Fatal(err)
	}
	// Bare address, no mask: the eks template writes "/32" around the token itself,
	// so returning a CIDR here would produce "203.0.113.7/32/32".
	if ip != "203.0.113.7" {
		t.Errorf("got %q, want the bare address 203.0.113.7", ip)
	}
}

func TestDetectEgressIPFailuresPointAtTheEscapeHatch(t *testing.T) {
	for _, test := range []struct {
		name string
		doer stubDoer
	}{
		{"unreachable", func(*http.Request) (*http.Response, error) {
			return nil, errors.New("no route to host")
		}},
		{"non-200", func(*http.Request) (*http.Response, error) {
			return response(503, ""), nil
		}},
	} {
		t.Run(test.name, func(t *testing.T) {
			_, err := DetectEgressIP(context.Background(), test.doer)
			if err == nil {
				t.Fatal("expected an error")
			}
			// An airgapped machine must be told how to proceed, not just that it failed.
			if !strings.Contains(err.Error(), "--api-cidr") {
				t.Errorf("error should name the explicit escape hatch, got: %v", err)
			}
		})
	}
}

func TestDetectEgressIPRejectsGarbage(t *testing.T) {
	_, err := DetectEgressIP(context.Background(),
		stubDoer(func(*http.Request) (*http.Response, error) {
			return response(200, "<html>captive portal</html>"), nil
		}))
	if err == nil {
		t.Fatal("a captive portal answering 200 must not become the API CIDR")
	}
}

// authoringCheckout builds a repository just deep enough for the write path.
func authoringCheckout(t *testing.T) Layout {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "examples", "aws", "_modules"), 0o755); err != nil {
		t.Fatal(err)
	}
	return Layout{Root: root}
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	content, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	return string(content)
}

func TestWriteEnvironmentsConfCreates(t *testing.T) {
	layout := authoringCheckout(t)
	spec := EnvSpec{Environment: "dev", AccountID: "123456789012", Profile: "lerian-dev", Region: "us-east-2"}

	result, err := WriteEnvironmentsConf(layout, []EnvSpec{spec}, WriteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Action != WriteCreated {
		t.Errorf("action = %q, want created", result.Action)
	}

	// The file this package writes must load back through this package's own reader.
	loaded, err := LoadEnvConfig(layout, "dev")
	if err != nil {
		t.Fatalf("a generated environments.conf must load: %v", err)
	}
	if loaded.AccountID != spec.AccountID || loaded.Profile != spec.Profile || loaded.Region != spec.Region {
		t.Errorf("round trip lost data: %+v", loaded)
	}
}

func TestWriteEnvironmentsConfPreservesCommentsAndOtherSections(t *testing.T) {
	layout := authoringCheckout(t)
	path := layout.ConfigFile()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	original := "# our own note about prd\n[prd]\naccount_id = 345678901234\nprofile    = lerian-prd\nregion     = us-east-1\n"
	if err := os.WriteFile(path, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := WriteEnvironmentsConf(layout,
		[]EnvSpec{{Environment: "dev", AccountID: "123456789012", Profile: "d", Region: "us-east-2"}},
		WriteOptions{})
	if err != nil {
		t.Fatal(err)
	}

	got := readFile(t, path)
	// Adding a section must not disturb anything else in the file.
	if !strings.Contains(got, "# our own note about prd") {
		t.Error("the operator's comment was lost")
	}
	if !strings.Contains(got, "[prd]") || !strings.Contains(got, "345678901234") {
		t.Errorf("the untouched section was damaged:\n%s", got)
	}
	if !strings.Contains(got, "[dev]") {
		t.Errorf("the new section is missing:\n%s", got)
	}
}

func TestWriteEnvironmentsConfConflictAndForce(t *testing.T) {
	layout := authoringCheckout(t)
	first := EnvSpec{Environment: "dev", AccountID: "123456789012", Profile: "a", Region: "us-east-2"}
	if _, err := WriteEnvironmentsConf(layout, []EnvSpec{first}, WriteOptions{}); err != nil {
		t.Fatal(err)
	}

	// Same content again is unchanged, so re-running init is safe.
	again, err := WriteEnvironmentsConf(layout, []EnvSpec{first}, WriteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if again.Action != WriteUnchanged {
		t.Errorf("re-writing identical content = %q, want unchanged", again.Action)
	}

	// A different account for the same environment is the dangerous case: it must
	// stop, and it must not have touched the file.
	changed := EnvSpec{Environment: "dev", AccountID: "210987654321", Profile: "a", Region: "us-east-2"}
	conflict, err := WriteEnvironmentsConf(layout, []EnvSpec{changed}, WriteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if conflict.Action != WriteConflict {
		t.Fatalf("action = %q, want conflict", conflict.Action)
	}
	if conflict.OK() {
		t.Error("a conflict must not report OK")
	}
	if got := readFile(t, layout.ConfigFile()); strings.Contains(got, "210987654321") {
		t.Error("a conflict must leave the file untouched")
	}
	if conflict.Diff == "" {
		t.Error("a conflict must show what differs, or it cannot be resolved")
	}

	forced, err := WriteEnvironmentsConf(layout, []EnvSpec{changed}, WriteOptions{Force: true})
	if err != nil {
		t.Fatal(err)
	}
	if forced.Action != WriteOverwritten {
		t.Errorf("action = %q, want overwritten", forced.Action)
	}
	if got := readFile(t, layout.ConfigFile()); !strings.Contains(got, "210987654321") {
		t.Error("force must actually replace the value")
	}
}

func TestWriteEnvironmentsConfDryRunWritesNothing(t *testing.T) {
	layout := authoringCheckout(t)
	result, err := WriteEnvironmentsConf(layout,
		[]EnvSpec{{Environment: "dev", AccountID: "123456789012", Profile: "a", Region: "us-east-2"}},
		WriteOptions{DryRun: true})
	if err != nil {
		t.Fatal(err)
	}
	if result.Action != WriteCreated {
		t.Errorf("a dry run must still report what it would do, got %q", result.Action)
	}
	if result.Diff == "" {
		t.Error("a dry run is only useful if it shows the content")
	}
	if _, err := os.Stat(layout.ConfigFile()); !os.IsNotExist(err) {
		t.Error("dry run wrote the file")
	}
}

func TestEnvSpecRejectsBadAccount(t *testing.T) {
	layout := authoringCheckout(t)
	for _, account := range []string{"", "12345", "89137722666a", "891-377-226-668"} {
		_, err := WriteEnvironmentsConf(layout,
			[]EnvSpec{{Environment: "dev", AccountID: account, Region: "us-east-2"}},
			WriteOptions{})
		if err == nil {
			t.Errorf("account_id %q should be rejected", account)
		}
	}
}

func TestEmptyProfileIsWrittenAsExplicitDash(t *testing.T) {
	// Ambient credentials are the CI shape. A blank value looks unfinished in a
	// file somebody will read later; "-" says it out loud, and the loader reads it
	// back as "no profile".
	layout := authoringCheckout(t)
	if _, err := WriteEnvironmentsConf(layout,
		[]EnvSpec{{Environment: "dev", AccountID: "123456789012", Profile: "", Region: "us-east-2"}},
		WriteOptions{}); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, layout.ConfigFile()); !strings.Contains(got, "profile    = -") {
		t.Errorf("expected an explicit dash:\n%s", got)
	}
	loaded, err := LoadEnvConfig(layout, "dev")
	if err != nil {
		t.Fatal(err)
	}
	if loaded.Profile != "" {
		t.Errorf("the dash must read back as no profile, got %q", loaded.Profile)
	}
}

// varFileUnit creates a root with a committed example, and returns it.
func varFileUnit(t *testing.T, layout Layout, name, example string) Unit {
	t.Helper()
	dir := filepath.Join(layout.ProductsDir(), "midaz", name)
	if err := os.MkdirAll(filepath.Join(dir, "envs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "envs", "dev.tfvars-example"), []byte(example), 0o644); err != nil {
		t.Fatal(err)
	}
	return Unit{Dir: dir, Name: "products/midaz/" + name}
}

func TestMaterializeVarFileKeepsCommentsAndSubstitutes(t *testing.T) {
	layout := authoringCheckout(t)
	// The comment matters: the committed examples carry the cost and sizing notes,
	// and regenerating instead of copying would throw them away.
	example := "# rabbitmq mq.m7g.medium is about US$100/month\n" +
		"instance_type = \"mq.m7g.medium\"\n" +
		"allowed_api_access_cidrs = [\n  \"" + EgressIPPlaceholders[0] + "/32\",\n]\n"
	unit := varFileUnit(t, layout, "rabbitmq", example)

	result, err := MaterializeVarFile(layout, VarFileRequest{
		Unit:         unit,
		Env:          "dev",
		Replacements: map[string]string{EgressIPPlaceholders[0]: "203.0.113.7"},
	}, WriteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if result.Action != WriteCreated {
		t.Fatalf("action = %q, want created", result.Action)
	}

	got := readFile(t, VarFile(unit, "dev"))
	if !strings.Contains(got, "US$100/month") {
		t.Error("the cost comment was lost; materialise must copy, not regenerate")
	}
	if !strings.Contains(got, `"203.0.113.7/32"`) {
		t.Errorf("substitution produced the wrong CIDR:\n%s", got)
	}
	if strings.Contains(got, EgressIPPlaceholders[0]) {
		t.Error("the placeholder survived substitution")
	}
	if len(result.Pending) != 0 {
		t.Errorf("nothing should be pending, got %v", result.Pending)
	}
}

func TestMaterializeVarFileReportsUnfilledPlaceholders(t *testing.T) {
	layout := authoringCheckout(t)
	unit := varFileUnit(t, layout, "postgres",
		"# see <that address> in the docs\nname = \"<PUT-YOUR-NAME-HERE>\"\n")

	result, err := MaterializeVarFile(layout, VarFileRequest{Unit: unit, Env: "dev"}, WriteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	// Created but not ready is a real state, and the caller has to be able to see it.
	if result.Action != WriteCreated {
		t.Errorf("action = %q, want created", result.Action)
	}
	if len(result.Pending) != 1 || result.Pending[0] != "<PUT-YOUR-NAME-HERE>" {
		t.Errorf("pending = %v, want the one real token", result.Pending)
	}
}

func TestMaterializeVarFileMissingExample(t *testing.T) {
	layout := authoringCheckout(t)
	dir := filepath.Join(layout.ProductsDir(), "midaz", "nothing")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	_, err := MaterializeVarFile(layout,
		VarFileRequest{Unit: Unit{Dir: dir, Name: "products/midaz/nothing"}, Env: "dev"},
		WriteOptions{})
	if err == nil {
		t.Fatal("expected an error naming the missing example")
	}
	if !strings.Contains(err.Error(), "tfvars-example") {
		t.Errorf("error should name what is missing, got: %v", err)
	}
}

func TestPlaceholdersInIgnoresComments(t *testing.T) {
	layout := authoringCheckout(t)
	unit := varFileUnit(t, layout, "valkey",
		"# replace <PUT-YOUR-COMMENT-HERE> as described\nreal = \"<PUT-YOUR-VALUE-HERE>\"\n")

	tokens, err := PlaceholdersIn(unit, "dev")
	if err != nil {
		t.Fatal(err)
	}
	if len(tokens) != 1 || tokens[0] != "<PUT-YOUR-VALUE-HERE>" {
		t.Errorf("tokens = %v; prose in comments is not an unresolved value", tokens)
	}
}

func TestWritesAreConfinedToTheAWSDirectory(t *testing.T) {
	layout := authoringCheckout(t)
	// A target name is operator input. It does not get to choose where bytes land.
	escaping := Unit{
		Dir:  filepath.Join(layout.ProductsDir(), "..", "..", "..", "..", "elsewhere"),
		Name: "escaping",
	}
	if err := os.MkdirAll(filepath.Join(escaping.Dir, "envs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(escaping.Dir, "envs", "dev.tfvars-example"), []byte("x = 1\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	_, err := MaterializeVarFile(layout, VarFileRequest{Unit: escaping, Env: "dev"}, WriteOptions{})
	if err == nil {
		t.Fatal("a write outside examples/aws must be refused")
	}
	if !strings.Contains(err.Error(), "refusing to write outside") {
		t.Errorf("unexpected error: %v", err)
	}
}

// Conflict in environments.conf is judged per section, not per file. Getting this
// wrong made adding [stg] to a file that already had [dev] report a conflict and
// write nothing, which would have blocked the second environment entirely.
func TestEnvironmentsConfConflictIsPerSectionNotPerFile(t *testing.T) {
	layout := authoringCheckout(t)
	dev := EnvSpec{Environment: "dev", AccountID: "123456789012", Profile: "d", Region: "us-east-2"}
	if _, err := WriteEnvironmentsConf(layout, []EnvSpec{dev}, WriteOptions{}); err != nil {
		t.Fatal(err)
	}

	// A different section: new content in the file, but nothing replaced.
	stg := EnvSpec{Environment: "stg", AccountID: "210987654321", Profile: "s", Region: "us-east-2"}
	added, err := WriteEnvironmentsConf(layout, []EnvSpec{stg}, WriteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if added.Action == WriteConflict {
		t.Fatal("adding a new section replaces nothing and must not be a conflict")
	}

	// Both must now load, and dev must be untouched.
	for _, want := range []EnvSpec{dev, stg} {
		got, err := LoadEnvConfig(layout, want.Environment)
		if err != nil {
			t.Fatalf("[%s] must load: %v", want.Environment, err)
		}
		if got.AccountID != want.AccountID {
			t.Errorf("[%s] account = %q, want %q", want.Environment, got.AccountID, want.AccountID)
		}
	}

	// Changing an existing section IS a replacement.
	moved := EnvSpec{Environment: "dev", AccountID: "111111111111", Profile: "d", Region: "us-east-2"}
	conflict, err := WriteEnvironmentsConf(layout, []EnvSpec{moved}, WriteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if conflict.Action != WriteConflict {
		t.Errorf("repointing an existing environment at another account = %q, want conflict", conflict.Action)
	}
}

// The committed templates are the source of truth for which values an operator has
// to supply. If one grows a placeholder that EgressIPPlaceholders does not cover,
// init would write a tfvars that cannot be applied and only report it as "pending"
// — so the drift has to fail the build instead.
//
// This test reads the real repository, not a fixture: a fixture would drift too.
func TestEveryTemplatePlaceholderIsKnown(t *testing.T) {
	root := filepath.Join("..", "..", "examples", "aws")
	if _, err := os.Stat(root); err != nil {
		t.Skipf("not running inside a checkout: %v", err)
	}

	unknown := map[string][]string{}
	err := filepath.WalkDir(root, func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".tfvars-example") {
			return nil
		}
		content, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		for _, token := range placeholderTokens(content) {
			if !IsEgressPlaceholder(token) {
				unknown[token] = append(unknown[token], path)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}

	for token, files := range unknown {
		t.Errorf("template placeholder %s is not covered by EgressIPPlaceholders "+
			"and has no way to be filled automatically.\n"+
			"Either add it there with a way to answer it, or make sure `init --set %s=...`\n"+
			"is documented for it. Found in:\n  %s",
			token, token, strings.Join(files, "\n  "))
	}
}

// An organisation with a dozen account profiles behind one SSO session needs one
// login, not a dozen. Suggesting a per-profile command for each of them was
// technically correct and practically useless.
func TestLoginHintCollapsesASharedSSOSession(t *testing.T) {
	resolved := []ResolvedProfile{
		{Profile: AWSProfile{Name: "dev", SSOSession: "acme-sso"}, Err: errors.New("expired")},
		{Profile: AWSProfile{Name: "stg", SSOSession: "acme-sso"}, Err: errors.New("expired")},
		{Profile: AWSProfile{Name: "prd", SSOSession: "acme-sso"}, Err: errors.New("expired")},
	}

	hint := LoginHint(resolved)
	if hint != "aws sso login --sso-session acme-sso" {
		t.Errorf("three profiles on one session need one command, got:\n%s", hint)
	}
}

func TestLoginHintNamesProfilesWithoutASession(t *testing.T) {
	resolved := []ResolvedProfile{
		{Profile: AWSProfile{Name: "shared", SSOSession: "acme-sso"}, Err: errors.New("expired")},
		{Profile: AWSProfile{Name: "standalone"}, Err: errors.New("expired")},
		// A working profile contributes nothing to the hint.
		{Profile: AWSProfile{Name: "fine"}, Caller: Caller{Account: "123456789012"}},
	}

	hint := LoginHint(resolved)
	if !strings.Contains(hint, "--sso-session acme-sso") {
		t.Errorf("the shared session is missing:\n%s", hint)
	}
	if !strings.Contains(hint, "--profile standalone") {
		t.Errorf("a profile outside any session must be named:\n%s", hint)
	}
	if strings.Contains(hint, "fine") {
		t.Errorf("a working profile must not appear:\n%s", hint)
	}
}

func TestLoginHintIsEmptyWhenEverythingWorks(t *testing.T) {
	resolved := []ResolvedProfile{
		{Profile: AWSProfile{Name: "dev"}, Caller: Caller{Account: "123456789012"}},
	}
	if hint := LoginHint(resolved); hint != "" {
		t.Errorf("nothing is broken, so there is nothing to suggest, got: %q", hint)
	}
}

func TestListAWSProfilesReadsSSOSession(t *testing.T) {
	dir := awsHome(t,
		"[sso-session acme-sso]\nsso_start_url = https://example.awsapps.com/start\n\n"+
			"[profile dev]\nsso_session = acme-sso\nregion = us-east-2\n", "")

	profiles, err := listAWSProfilesIn(dir)
	if err != nil {
		t.Fatal(err)
	}
	for _, profile := range profiles {
		if profile.Name == "dev" {
			if profile.SSOSession != "acme-sso" {
				t.Errorf("sso_session = %q, want acme-sso", profile.SSOSession)
			}
			return
		}
	}
	t.Fatal("profile dev was not found")
}

// environments.conf records a region but does not inject it into Terraform: each
// root takes its region from its own tfvars. Materialising a us-east-1 template
// into a checkout configured for us-east-2 therefore deployed to us-east-1 while
// every guard reported agreement, because the guards only compare environments.conf
// with backend/<env>.hcl and never look at the tfvars.
func TestMaterializeVarFileRetargetsRegionAndZones(t *testing.T) {
	layout := authoringCheckout(t)
	example := "# roughly USD 100/month (us-east-1 on-demand, ESTIMATE)\n" +
		"region             = \"us-east-1\"\n" +
		"availability_zones = [\"us-east-1a\", \"us-east-1b\", \"us-east-1c\"]\n"
	unit := varFileUnit(t, layout, "vpc", example)

	result, err := MaterializeVarFile(layout,
		VarFileRequest{Unit: unit, Env: "dev", Region: "us-east-2"}, WriteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if result.RetargetedFrom != "us-east-1" {
		t.Errorf("RetargetedFrom = %q; a region move must be reported, not silent", result.RetargetedFrom)
	}

	got := readFile(t, VarFile(unit, "dev"))
	if !strings.Contains(got, `region             = "us-east-2"`) {
		t.Errorf("region was not retargeted:\n%s", got)
	}
	// The zones carry the region in their names; leaving them behind produces a
	// zone that does not exist in the new region, and that fails only at apply.
	if !strings.Contains(got, `"us-east-2a"`) || strings.Contains(got, `"us-east-1a"`) {
		t.Errorf("availability zones were not retargeted with the region:\n%s", got)
	}
	// The price was quoted for a specific region. Rewriting it inside the comment
	// would turn an accurate note into a wrong one.
	if !strings.Contains(got, "us-east-1 on-demand") {
		t.Errorf("a region named inside a comment must be left alone:\n%s", got)
	}
}

func TestMaterializeVarFileLeavesMatchingRegionAlone(t *testing.T) {
	layout := authoringCheckout(t)
	unit := varFileUnit(t, layout, "same", "region = \"us-east-2\"\n")

	result, err := MaterializeVarFile(layout,
		VarFileRequest{Unit: unit, Env: "dev", Region: "us-east-2"}, WriteOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if result.RetargetedFrom != "" {
		t.Errorf("nothing moved, so nothing should be reported, got %q", result.RetargetedFrom)
	}
}

// The dedicated/shared switch is written by the tool, not inherited from the
// template. Before this, a checkout was dedicated because the template said so and
// nothing ever asked.
func TestMaterializeVarFileSetsMode(t *testing.T) {
	layout := authoringCheckout(t)
	// The neighbouring key is the trap: an unanchored pattern for "mode =" also
	// matches transit_encryption_mode and would silently rewrite the TLS setting.
	example := "mode = \"dedicated\"\n" +
		"transit_encryption_mode    = \"preferred\"\n" +
		"# With mode = \"shared\" this stack creates nothing.\n"
	unit := varFileUnit(t, layout, "valkey", example)

	if _, err := MaterializeVarFile(layout,
		VarFileRequest{Unit: unit, Env: "dev", Mode: SharedMode}, WriteOptions{}); err != nil {
		t.Fatal(err)
	}

	got := readFile(t, VarFile(unit, "dev"))
	if !strings.Contains(got, "mode = \"shared\"") {
		t.Errorf("the mode was not set:\n%s", got)
	}
	if !strings.Contains(got, "transit_encryption_mode    = \"preferred\"") {
		t.Errorf("transit_encryption_mode was rewritten; the pattern is not anchored:\n%s", got)
	}
	// The prose explaining the other mode stays: rewriting it would leave the file
	// describing a choice it no longer makes.
	if !strings.Contains(got, "# With mode = \"shared\" this stack creates nothing.") {
		t.Errorf("a comment was rewritten:\n%s", got)
	}
}

func TestMaterializeVarFileRejectsUnknownMode(t *testing.T) {
	layout := authoringCheckout(t)
	unit := varFileUnit(t, layout, "postgres", "mode = \"dedicated\"\n")

	_, err := MaterializeVarFile(layout,
		VarFileRequest{Unit: unit, Env: "dev", Mode: "hybrid"}, WriteOptions{})
	if err == nil {
		t.Fatal("an unknown mode must be refused before it reaches a tfvars")
	}
	if !strings.Contains(err.Error(), "dedicated") {
		t.Errorf("the error should list the valid values, got: %v", err)
	}
}

// An empty Mode leaves the template's own value alone, which is what keeps this
// optional for callers that do not care.
func TestMaterializeVarFileLeavesModeAloneWhenUnset(t *testing.T) {
	layout := authoringCheckout(t)
	unit := varFileUnit(t, layout, "docdb", "mode = \"dedicated\"\n")

	if _, err := MaterializeVarFile(layout,
		VarFileRequest{Unit: unit, Env: "dev"}, WriteOptions{}); err != nil {
		t.Fatal(err)
	}
	if got := readFile(t, VarFile(unit, "dev")); !strings.Contains(got, "mode = \"dedicated\"") {
		t.Errorf("an unset Mode must not change the file:\n%s", got)
	}
}
