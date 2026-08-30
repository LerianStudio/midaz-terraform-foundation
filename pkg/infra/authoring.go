package infra

// Authoring is the half of this package that WRITES into the operator's checkout.
//
// Everything else here only reads: it loads environments.conf, discovers roots and
// runs Terraform. That asymmetry was the reason a fresh clone needed a text editor
// before it could do anything, and the reason a graphical front end would have had
// to reimplement the file formats to offer the same thing.
//
// So the rule this file exists to enforce: every capability lives here, and both
// the CLI and the wizard are thin clients over it. An interactive prompt is sugar
// over a flag; a flag is sugar over one of these functions. If a capability is not
// in this file, neither client has it.
//
// Writing into somebody's repository earns three obligations the read path never
// had, and they are enforced here rather than trusted to callers:
//
//   - Nothing is overwritten without Force. An existing file that differs is a
//     WriteConflict the caller must resolve, never a silent merge.
//   - Writes are atomic (temp file, then rename), so an interrupt cannot leave a
//     half-written tfvars that Terraform would happily parse.
//   - Every path is confined under examples/aws. A target name is operator input,
//     and operator input does not get to choose where bytes land.

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
)

// EgressIPPlaceholders are the tokens the committed templates leave for the
// address allowed to reach the Kubernetes API — the only values in this repository
// a machine can offer to fill in on its own.
//
// There are two spellings because the templates ask slightly different questions:
// dev wants the operator's own egress address, stg wants the office range. Both are
// answered by the same input, and both are always confirmed rather than filled
// silently, because a wrong CIDR here locks the cluster's API away.
//
// This list lives here, not in the CLI, so both front ends fill the same tokens.
// TestEveryTemplatePlaceholderIsKnown fails if a template ever grows a token this
// list does not cover, which is the only way to notice that drift.
var EgressIPPlaceholders = []string{
	"<PUT-YOUR-EGRESS-IP-HERE>",
	"<PUT-YOUR-OFFICE-EGRESS-IP-HERE>",
}

// IsEgressPlaceholder reports whether a token is answered by the egress address.
func IsEgressPlaceholder(token string) bool {
	for _, known := range EgressIPPlaceholders {
		if token == known {
			return true
		}
	}
	return false
}

// egressIPService is AWS's own echo endpoint, which is what the eks template's
// comment already tells the operator to curl.
const egressIPService = "https://checkip.amazonaws.com"

// AWSProfile is one named profile found in the operator's AWS configuration.
type AWSProfile struct {
	// Name is the profile name as AWS_PROFILE would take it: the section name with
	// the "profile " prefix of ~/.aws/config already stripped.
	Name string
	// Region is the profile's own region, when it declares one. It is a suggestion
	// for the region prompt, never an override of environments.conf.
	Region string
	// Source is "config" or "credentials", which is worth showing: a profile that
	// exists only in ~/.aws/credentials has no SSO session to expire.
	Source string
	// SSOSession is the [sso-session <name>] this profile logs in through, when it
	// uses one. Profiles that share a session share a login: an organisation with a
	// dozen account profiles behind one SSO session needs one command to revive all
	// of them, not one per profile.
	SSOSession string
}

// ListAWSProfiles reads ~/.aws/config and ~/.aws/credentials and returns every
// profile it finds, sorted by name.
//
// A missing file is not an error: a machine with only environment credentials has
// neither, and that is the CI shape this repository already supports.
func ListAWSProfiles() ([]AWSProfile, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, fmt.Errorf("infra: cannot locate the home directory to read the AWS configuration: %w", err)
	}
	return listAWSProfilesIn(filepath.Join(home, ".aws"))
}

// listAWSProfilesIn is ListAWSProfiles with the directory injected, so the tests
// do not depend on the machine running them.
func listAWSProfilesIn(dir string) ([]AWSProfile, error) {
	found := map[string]AWSProfile{}

	// ~/.aws/config spells profiles "[profile name]", except the default one, which
	// is bare "[default]". ~/.aws/credentials spells them all bare.
	for _, source := range []struct {
		file   string
		prefix string
	}{
		{filepath.Join(dir, "config"), "profile "},
		{filepath.Join(dir, "credentials"), ""},
	} {
		file, err := os.Open(source.file)
		if err != nil {
			if os.IsNotExist(err) {
				continue
			}
			return nil, fmt.Errorf("infra: cannot read %s: %w", source.file, err)
		}
		sections, parseErr := parseINI(file)
		_ = file.Close()
		if parseErr != nil {
			return nil, fmt.Errorf("infra: cannot read %s: %w", source.file, parseErr)
		}

		kind := "credentials"
		if source.prefix != "" {
			kind = "config"
		}
		for section, values := range sections {
			name := section
			switch {
			case source.prefix != "" && strings.HasPrefix(section, source.prefix):
				name = strings.TrimSpace(strings.TrimPrefix(section, source.prefix))
			case source.prefix != "" && section != "default":
				// A section in ~/.aws/config that is neither "default" nor
				// "profile x" is something else entirely (sso-session, services).
				continue
			}
			if name == "" {
				continue
			}
			// config wins: it is the file that carries the region.
			if existing, seen := found[name]; seen && existing.Source == "config" {
				continue
			}
			found[name] = AWSProfile{
				Name:       name,
				Region:     values["region"],
				Source:     kind,
				SSOSession: values["sso_session"],
			}
		}
	}

	profiles := make([]AWSProfile, 0, len(found))
	for _, profile := range found {
		profiles = append(profiles, profile)
	}
	sort.Slice(profiles, func(i, j int) bool { return profiles[i].Name < profiles[j].Name })
	return profiles, nil
}

// ResolvedProfile is a profile plus the answer to the only question that matters
// about it: which account does it actually reach, right now.
type ResolvedProfile struct {
	Profile AWSProfile
	Caller  Caller
	// Err is the reason this profile cannot be used, most often an expired SSO
	// session. It is carried per profile rather than returned, because one dead
	// profile must not hide the working ones.
	Err error
}

// Usable reports whether this profile resolved to an account.
func (r ResolvedProfile) Usable() bool { return r.Err == nil && r.Caller.Account != "" }

// LoginHint returns the single command that would revive the failed profiles.
//
// It exists because the obvious message is the wrong one. Suggesting
// "aws sso login --profile X" once per profile produces a dozen identical-looking
// lines for an organisation whose profiles all sit behind one SSO session, and
// hides the fact that one login fixes every one of them.
func LoginHint(resolved []ResolvedProfile) string {
	sessions := map[string]bool{}
	var profiles []string
	for _, entry := range resolved {
		if entry.Usable() {
			continue
		}
		if entry.Profile.SSOSession != "" {
			sessions[entry.Profile.SSOSession] = true
			continue
		}
		profiles = append(profiles, entry.Profile.Name)
	}

	var commands []string
	names := make([]string, 0, len(sessions))
	for session := range sessions {
		names = append(names, session)
	}
	sort.Strings(names)
	for _, session := range names {
		commands = append(commands, "aws sso login --sso-session "+session)
	}
	// Profiles outside any SSO session have to be named one by one, but they are
	// usually few; cap the list so a broken machine does not print a wall of them.
	sort.Strings(profiles)
	for i, profile := range profiles {
		if i == 3 {
			commands = append(commands, fmt.Sprintf("... and %d more", len(profiles)-i))
			break
		}
		commands = append(commands, "aws sso login --profile "+profile)
	}
	return strings.Join(commands, "\n  ")
}

// ResolveProfiles asks each profile who it is, concurrently, and returns the
// answers in the order the profiles were given.
//
// This is the same Identity the account guard uses, on purpose: the profile shown
// as reaching account X here is the profile the guard will later check against
// environments.conf, so the two cannot disagree.
func ResolveProfiles(
	ctx context.Context,
	identity Identity,
	profiles []AWSProfile,
	region string,
) []ResolvedProfile {
	resolved := make([]ResolvedProfile, len(profiles))

	semaphore := make(chan struct{}, 8)
	var wg sync.WaitGroup
	wg.Add(len(profiles))

	for i, profile := range profiles {
		go func(i int, profile AWSProfile) {
			defer wg.Done()
			semaphore <- struct{}{}
			defer func() { <-semaphore }()

			// The profile's own region is the better guess when the caller has no
			// opinion yet, which is the case on the very first run.
			effective := region
			if effective == "" {
				effective = profile.Region
			}
			caller, err := identity.CallerIdentity(ctx, profile.Name, effective)
			resolved[i] = ResolvedProfile{Profile: profile, Caller: caller, Err: err}
		}(i, profile)
	}
	wg.Wait()
	return resolved
}

// HTTPDoer is the slice of *http.Client that egress detection needs.
type HTTPDoer interface {
	Do(request *http.Request) (*http.Response, error)
}

// DetectEgressIP returns the public address this machine appears to come from.
//
// It returns the bare address, not a CIDR: the eks template already writes the
// mask around the token ("<...>/32"), so substituting a CIDR here would produce
// "1.2.3.4/32/32" and a plan error far from its cause.
func DetectEgressIP(ctx context.Context, client HTTPDoer) (string, error) {
	if client == nil {
		client = &http.Client{}
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, egressIPService, nil)
	if err != nil {
		return "", fmt.Errorf("infra: cannot build the egress lookup request: %w", err)
	}
	response, err := client.Do(request)
	if err != nil {
		return "", fmt.Errorf("infra: cannot reach %s to detect this machine's egress address: %w\n"+
			"Pass the address explicitly instead of detecting it (see --api-cidr).",
			egressIPService, err)
	}
	defer func() { _ = response.Body.Close() }()

	if response.StatusCode != http.StatusOK {
		return "", fmt.Errorf("infra: %s answered %s\n"+
			"Pass the address explicitly instead of detecting it (see --api-cidr).",
			egressIPService, response.Status)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, 128))
	if err != nil {
		return "", fmt.Errorf("infra: cannot read the answer from %s: %w", egressIPService, err)
	}
	address := strings.TrimSpace(string(body))
	if net.ParseIP(address) == nil {
		return "", fmt.Errorf("infra: %s returned %q, which is not an IP address", egressIPService, address)
	}
	return address, nil
}

// WriteAction is what a write did, or would do.
type WriteAction string

const (
	// WriteCreated means the file did not exist and now does.
	WriteCreated WriteAction = "created"
	// WriteUnchanged means the file already held exactly this content.
	WriteUnchanged WriteAction = "unchanged"
	// WriteConflict means the file exists with different content and Force was not
	// set. Nothing was written.
	WriteConflict WriteAction = "conflict"
	// WriteOverwritten means the file existed, differed, and Force replaced it.
	WriteOverwritten WriteAction = "overwritten"
)

// WriteOptions controls how far a write goes.
type WriteOptions struct {
	// Force replaces a file that exists and differs. Without it, that is a conflict.
	Force bool
	// DryRun computes the result, including the diff, and writes nothing. This is
	// what makes one function serve both a --dry-run flag and a review screen.
	DryRun bool
}

// WriteResult is what happened, or what would happen under DryRun.
type WriteResult struct {
	Path   string
	Action WriteAction
	// Diff is human-readable and meant to be shown before a confirmation: the full
	// content for a new file, the differing lines for a conflict.
	Diff string
	// Pending lists placeholder tokens still present in the written content. A
	// result can be WriteCreated and still not be ready to apply.
	Pending []string
	// RetargetedFrom names the region the template declared, when it differed from
	// the one asked for and the file was rewritten. Empty when no move happened.
	// Shown rather than kept quiet: moving a deployment between regions is not a
	// detail an operator should discover from a bill.
	RetargetedFrom string
}

// OK reports whether this result left the file in the requested state.
func (r WriteResult) OK() bool { return r.Action != WriteConflict }

// EnvSpec is one [<env>] section of environments.conf.
type EnvSpec struct {
	Environment string
	AccountID   string
	Profile     string
	Region      string
}

// Validate checks the spec before it reaches the file, with the same rules the
// loader applies when reading it back.
func (s EnvSpec) Validate() error {
	if strings.TrimSpace(s.Environment) == "" {
		return fmt.Errorf("infra: the environment name is required")
	}
	// The same rule the loader enforces when it reads the file back, so a file this
	// package writes can never fail this package's own validation.
	if !isTwelveDigits(s.AccountID) {
		return fmt.Errorf("infra: invalid account_id for [%s]: %q\n"+
			"An AWS account id is exactly 12 digits, no dashes and no quotes.",
			s.Environment, s.AccountID)
	}
	if strings.TrimSpace(s.Region) == "" {
		return fmt.Errorf("infra: a region is required for [%s]", s.Environment)
	}
	return nil
}

// render writes the section body, in the order and spacing of the committed
// example so a generated file and a hand-written one are indistinguishable.
func (s EnvSpec) render() []string {
	profile := s.Profile
	if strings.TrimSpace(profile) == "" {
		// The loader reads "-" as an explicit "no profile, use ambient credentials",
		// which is clearer in a file than a blank value that looks unfinished.
		profile = "-"
	}
	return []string{
		"[" + s.Environment + "]",
		"account_id = " + s.AccountID,
		"profile    = " + profile,
		"region     = " + s.Region,
	}
}

// WriteEnvironmentsConf upserts one or more [<env>] sections in environments.conf.
//
// It is an upsert at the level of lines, not a regeneration: everything outside the
// sections named in specs survives byte for byte, including the operator's own
// comments. Adding a section that was absent is a creation; changing one that was
// present needs Force.
func WriteEnvironmentsConf(layout Layout, specs []EnvSpec, opts WriteOptions) (WriteResult, error) {
	path := layout.ConfigFile()
	result := WriteResult{Path: path}

	if len(specs) == 0 {
		return result, fmt.Errorf("infra: no environment given to write into %s", layout.RepoRel(path))
	}
	for _, spec := range specs {
		if err := spec.Validate(); err != nil {
			return result, err
		}
	}

	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return result, fmt.Errorf("infra: cannot read %s: %w", layout.RepoRel(path), err)
	}

	// Conflict is judged per section, not per file. Adding a [stg] section to a file
	// that already describes [dev] replaces nothing, so it is a creation; only
	// changing a section that is already there can lose an operator's work.
	updated := existing
	replacing := false
	for _, spec := range specs {
		body := spec.render()
		if sectionDiffers(updated, spec.Environment, body) {
			replacing = true
		}
		updated = upsertINISection(updated, spec.Environment, body)
	}

	return commitWrite(layout, path, existing, updated, replacing, opts)
}

// sectionDiffers reports whether [name] already exists in content with a body
// different from the one proposed. An absent section does not differ: it is new.
func sectionDiffers(content []byte, name string, body []string) bool {
	header := "[" + name + "]"
	lines := splitLines(content)

	start := -1
	for i, line := range lines {
		if strings.TrimSpace(line) == header {
			start = i
			break
		}
	}
	if start < 0 {
		return false
	}

	end := len(lines)
	for i := start + 1; i < len(lines); i++ {
		trimmed := strings.TrimSpace(lines[i])
		if strings.HasPrefix(trimmed, "[") && strings.Contains(trimmed, "]") {
			end = i
			break
		}
	}

	var current []string
	for _, line := range lines[start:end] {
		if strings.TrimSpace(line) == "" {
			continue
		}
		current = append(current, strings.TrimSpace(line))
	}
	var proposed []string
	for _, line := range body {
		if strings.TrimSpace(line) == "" {
			continue
		}
		proposed = append(proposed, strings.TrimSpace(line))
	}
	if len(current) != len(proposed) {
		return true
	}
	for i := range current {
		if current[i] != proposed[i] {
			return true
		}
	}
	return false
}

// upsertINISection replaces the [name] section of content with body, or appends it
// when absent. Lines outside the section are untouched.
func upsertINISection(content []byte, name string, body []string) []byte {
	header := "[" + name + "]"
	lines := splitLines(content)

	start, end := -1, len(lines)
	for i, line := range lines {
		trimmed := strings.TrimSpace(line)
		if start < 0 {
			if trimmed == header {
				start = i
			}
			continue
		}
		// The section ends at the next header.
		if strings.HasPrefix(trimmed, "[") && strings.Contains(trimmed, "]") {
			end = i
			break
		}
	}

	if start < 0 {
		// Absent: append, with a blank line between sections when the file already
		// has content that does not end in one.
		out := lines
		if len(out) > 0 && strings.TrimSpace(out[len(out)-1]) != "" {
			out = append(out, "")
		}
		out = append(out, body...)
		return joinLines(out)
	}

	// Present: keep any trailing blank lines that belonged to the old section, so
	// repeated upserts do not slowly collapse the file's spacing.
	tail := end
	for tail > start+1 && strings.TrimSpace(lines[tail-1]) == "" {
		tail--
	}
	out := make([]string, 0, len(lines)-(tail-start)+len(body))
	out = append(out, lines[:start]...)
	out = append(out, body...)
	out = append(out, lines[tail:]...)
	return joinLines(out)
}

// VarFileRequest asks for one root's envs/<env>.tfvars to be materialised from the
// committed envs/<env>.tfvars-example next to it.
type VarFileRequest struct {
	Unit Unit
	Env  string
	// Replacements maps a placeholder token to the value that replaces it, for
	// example {EgressIPPlaceholders[0]: "203.0.113.7"}. Tokens with no entry are
	// left in place and reported in WriteResult.Pending.
	Replacements map[string]string
	// Region, when set, retargets the file away from whatever region its template
	// declares.
	//
	// This is not cosmetic. environments.conf records a region but does not inject
	// it into Terraform — every root takes its region from its own tfvars — so a
	// checkout configured for one region and materialised from a template that
	// hardcodes another deploys to the template's region while every guard reports
	// agreement. Availability zones are rewritten with it, because their names
	// embed the region and a zone from the wrong one fails only at apply time.
	Region string
	// Mode, when set, rewrites the datastore's dedicated/shared switch.
	//
	// Left empty the template's own default stands, which is how a checkout ended
	// up dedicated without anyone choosing it: the value existed, so no tool asked.
	Mode string
}

// Datastore modes. A root in DedicatedMode creates its own instance; in SharedMode
// it creates nothing and resolves the tier owned by products/shared-resources.
const (
	DedicatedMode = "dedicated"
	SharedMode    = "shared"
)

// ValidMode reports whether name is a datastore mode this repository understands.
func ValidMode(name string) bool {
	return name == DedicatedMode || name == SharedMode
}

// SupportsMode reports whether a root has a dedicated/shared switch at all.
//
// Not every datastore root has one, and the absence is a design decision rather
// than an omission: an S3 bucket is never shared between products, so the s3 roots
// carry no mode line and there is no s3 root in the shared tier for them to
// resolve. setMode only rewrites a line that already exists, so asking for shared
// mode leaves those roots dedicated — correctly, but silently. Callers use this to
// say so out loud instead.
//
// The example is read rather than the real tfvars because this answers what the
// root CAN do, which is a property of the template, not of a file the operator may
// not have yet.
func SupportsMode(unit Unit, env string) (bool, error) {
	example := VarFile(unit, env) + "-example"
	content, err := os.ReadFile(example)
	if err != nil {
		if os.IsNotExist(err) {
			return false, nil
		}
		return false, fmt.Errorf("infra: cannot read %s: %w", example, err)
	}
	for _, line := range splitLines(content) {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if modeAssignment.MatchString(line) {
			return true, nil
		}
	}
	return false, nil
}

// MaterializeVarFile copies a root's committed example into the real tfvars,
// substituting the placeholders it was given.
//
// It copies and substitutes rather than rendering a template from scratch, and that
// is deliberate: the examples carry the comments that explain the sizing and the
// cost of each choice — the RabbitMQ instance type alone is around US$100/month and
// the template says so. Regenerating the file would throw that away and leave the
// operator with values but no reasons.
func MaterializeVarFile(layout Layout, req VarFileRequest, opts WriteOptions) (WriteResult, error) {
	path := VarFile(req.Unit, req.Env)
	result := WriteResult{Path: path}

	example := path + "-example"
	template, err := os.ReadFile(example)
	if err != nil {
		if os.IsNotExist(err) {
			return result, fmt.Errorf("infra: %s has no %s.tfvars-example\n"+
				"This root may not support the %q environment. See what exists in %s.",
				req.Unit.Name, req.Env, req.Env, layout.RepoRel(filepath.Join(req.Unit.Dir, "envs")))
		}
		return result, fmt.Errorf("infra: cannot read %s: %w", layout.RepoRel(example), err)
	}

	rendered := template
	for token, value := range req.Replacements {
		rendered = bytes.ReplaceAll(rendered, []byte(token), []byte(value))
	}

	if req.Mode != "" {
		if !ValidMode(req.Mode) {
			return result, fmt.Errorf("infra: invalid mode %q for %s\nValid values: %s, %s.",
				req.Mode, req.Unit.Name, DedicatedMode, SharedMode)
		}
		rendered = setMode(rendered, req.Mode)
	}

	retargeted := ""
	if req.Region != "" {
		var from string
		rendered, from = retargetRegion(rendered, req.Region)
		if from != "" {
			retargeted = from
		}
	}

	existing, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		return result, fmt.Errorf("infra: cannot read %s: %w", layout.RepoRel(path), err)
	}

	// A tfvars that already exists is entirely the operator's: any difference is a
	// replacement, so the whole file is the unit of conflict here.
	written, err := commitWrite(layout, path, existing, rendered, existing != nil, opts)
	if err != nil {
		return written, err
	}
	// Report on what the file will actually hold, which is the rendered content even
	// when the write was skipped as a conflict.
	written.Pending = placeholderTokens(rendered)
	written.RetargetedFrom = retargeted
	return written, nil
}

// modeAssignment matches the datastore switch and nothing that merely ends in
// "mode". The anchor is the whole point: valkey's template also carries
// "transit_encryption_mode = \"preferred\"", and an unanchored pattern would
// rewrite the TLS setting while trying to change dedicated to shared.
var modeAssignment = regexp.MustCompile(`^(\s*mode\s*=\s*")[^"]*(")`)

// setMode rewrites the dedicated/shared switch, leaving comments untouched: the
// templates explain both modes in prose, and rewriting that prose would leave the
// file describing a choice it no longer makes.
func setMode(content []byte, mode string) []byte {
	lines := splitLines(content)
	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if modeAssignment.MatchString(line) {
			lines[i] = modeAssignment.ReplaceAllString(line, "${1}"+mode+"${2}")
		}
	}
	return joinLines(lines)
}

// regionAssignment finds a region literal in an uncommented HCL assignment.
var regionAssignment = regexp.MustCompile(`^\s*region\s*=\s*"([a-z0-9-]+)"`)

// retargetRegion rewrites a tfvars from the region its template declares to the
// one the operator chose, and returns the region it moved away from.
//
// Only uncommented lines are rewritten. The templates quote prices in a specific
// region ("roughly USD 100/month, us-east-1 on-demand"), and silently rewriting
// that region would turn an accurate note into a wrong one.
func retargetRegion(content []byte, region string) ([]byte, string) {
	lines := splitLines(content)

	from := ""
	for _, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if match := regionAssignment.FindStringSubmatch(line); match != nil {
			from = match[1]
			break
		}
	}
	if from == "" || from == region {
		return content, ""
	}

	for i, line := range lines {
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		lines[i] = strings.ReplaceAll(line, from, region)
	}
	return joinLines(lines), from
}

// PlaceholdersIn returns the distinct placeholder tokens still present in a root's
// committed example for an environment, so a caller can ask for exactly the values
// it needs instead of guessing which roots need input.
func PlaceholdersIn(unit Unit, env string) ([]string, error) {
	example := VarFile(unit, env) + "-example"
	content, err := os.ReadFile(example)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("infra: cannot read %s: %w", example, err)
	}
	return placeholderTokens(content), nil
}

// placeholderTokens lists the distinct tokens outside comment lines, sorted. The
// examples legitimately write things like "<that address>" in their prose, so a
// comment line is not evidence of an unresolved value.
func placeholderTokens(content []byte) []string {
	seen := map[string]bool{}
	scanner := bufio.NewScanner(bytes.NewReader(content))
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		for _, match := range placeholderPattern.FindAllString(line, -1) {
			seen[match] = true
		}
	}
	tokens := make([]string, 0, len(seen))
	for token := range seen {
		tokens = append(tokens, token)
	}
	sort.Strings(tokens)
	return tokens
}

// commitWrite is the single place bytes reach the filesystem, so the three
// obligations of the write path are enforced once rather than per caller.
// replacing says whether this change overwrites content the operator may have
// authored. It is a parameter rather than "the file differs" because the two are
// not the same thing: appending a section to environments.conf changes the file
// without replacing anything in it.
func commitWrite(
	layout Layout,
	path string,
	existing, desired []byte,
	replacing bool,
	opts WriteOptions,
) (WriteResult, error) {
	result := WriteResult{Path: path}

	if err := confine(layout, path); err != nil {
		return result, err
	}

	switch {
	case bytes.Equal(existing, desired):
		result.Action = WriteUnchanged
		return result, nil
	case existing == nil:
		result.Action = WriteCreated
		result.Diff = prefixLines(splitLines(desired), "+")
	case !replacing:
		result.Action = WriteCreated
		result.Diff = diffLines(existing, desired)
	case !opts.Force:
		result.Action = WriteConflict
		result.Diff = diffLines(existing, desired)
		return result, nil
	default:
		result.Action = WriteOverwritten
		result.Diff = diffLines(existing, desired)
	}

	if opts.DryRun {
		return result, nil
	}
	if err := writeAtomic(path, desired); err != nil {
		return result, err
	}
	return result, nil
}

// confine refuses any path outside examples/aws. Target names come from the
// operator, and an operator's typo does not get to choose where bytes land.
func confine(layout Layout, path string) error {
	root, err := filepath.Abs(layout.AWSDir())
	if err != nil {
		return fmt.Errorf("infra: cannot resolve %s: %w", layout.AWSDir(), err)
	}
	target, err := filepath.Abs(path)
	if err != nil {
		return fmt.Errorf("infra: cannot resolve %s: %w", path, err)
	}
	if target != root && !strings.HasPrefix(target, root+string(filepath.Separator)) {
		return fmt.Errorf("infra: refusing to write outside %s\n  path: %s",
			layout.RepoRel(root), target)
	}
	return nil
}

// writeAtomic writes through a temporary file in the same directory and renames it,
// so an interrupt leaves either the old file or the new one, never a truncated
// tfvars that Terraform would parse without complaint.
func writeAtomic(path string, content []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("infra: cannot create %s: %w", dir, err)
	}
	temp, err := os.CreateTemp(dir, "."+filepath.Base(path)+".*")
	if err != nil {
		return fmt.Errorf("infra: cannot create a temporary file in %s: %w", dir, err)
	}
	name := temp.Name()
	defer func() { _ = os.Remove(name) }()

	if _, err := temp.Write(content); err != nil {
		_ = temp.Close()
		return fmt.Errorf("infra: cannot write %s: %w", name, err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("infra: cannot close %s: %w", name, err)
	}
	if err := os.Chmod(name, 0o644); err != nil {
		return fmt.Errorf("infra: cannot set the mode of %s: %w", name, err)
	}
	if err := os.Rename(name, path); err != nil {
		return fmt.Errorf("infra: cannot move %s into place at %s: %w", name, path, err)
	}
	return nil
}

func splitLines(content []byte) []string {
	if len(content) == 0 {
		return nil
	}
	text := string(content)
	text = strings.TrimSuffix(text, "\n")
	return strings.Split(text, "\n")
}

func joinLines(lines []string) []byte {
	if len(lines) == 0 {
		return nil
	}
	return []byte(strings.Join(lines, "\n") + "\n")
}

func prefixLines(lines []string, marker string) string {
	var builder strings.Builder
	for _, line := range lines {
		builder.WriteString(marker + " " + line + "\n")
	}
	return builder.String()
}

// diffLines reports the lines that differ, which is enough to review a config file
// before confirming it and keeps this package free of a diff dependency.
func diffLines(before, after []byte) string {
	oldLines, newLines := splitLines(before), splitLines(after)
	present := map[string]bool{}
	for _, line := range oldLines {
		present[line] = true
	}
	kept := map[string]bool{}
	for _, line := range newLines {
		kept[line] = true
	}

	var builder strings.Builder
	for _, line := range oldLines {
		if !kept[line] {
			builder.WriteString("- " + line + "\n")
		}
	}
	for _, line := range newLines {
		if !present[line] {
			builder.WriteString("+ " + line + "\n")
		}
	}
	return builder.String()
}
