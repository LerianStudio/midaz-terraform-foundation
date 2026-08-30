package infra

// Credentials are resolved once for a whole run and handed to every Terraform
// process, instead of letting each one resolve the profile for itself.
//
// The reason is a race we caused. With AWS_PROFILE set, every terraform process
// resolves the profile independently, and for an SSO profile that means each one
// may decide the cached token needs refreshing. Four of them starting together —
// which is exactly what a parallel stage does — refresh concurrently and fight
// over the same file:
//
//	failed to replace old cached SSO token file, rename
//	~/.aws/sso/cache/<hash>.json.tmp-1787066430403425000 ->
//	~/.aws/sso/cache/<hash>.json: no such file or directory
//
// One process renames its temporary file into place, the next finds the one it
// wrote already gone. The failure is intermittent, depends on how many units share
// a stage, and reads like a broken credential rather than a collision.
//
// Resolving once removes the race by construction: the children receive concrete
// keys and never touch the SSO cache at all.

import (
	"context"
	"fmt"
	"os/exec"
	"strings"
)

// Credentials is a resolved, short-lived AWS credential set.
type Credentials struct {
	AccessKeyID     string
	SecretAccessKey string
	SessionToken    string
}

// Environment renders the credentials as environment variables for a child
// process. AWS_PROFILE is deliberately absent from the result: a child that sees
// both would resolve the profile and go back to the SSO cache.
func (c Credentials) Environment() map[string]string {
	if c.AccessKeyID == "" {
		return nil
	}
	env := map[string]string{
		"AWS_ACCESS_KEY_ID":     c.AccessKeyID,
		"AWS_SECRET_ACCESS_KEY": c.SecretAccessKey,
	}
	if c.SessionToken != "" {
		env["AWS_SESSION_TOKEN"] = c.SessionToken
	}
	return env
}

// ResolveCredentials asks the AWS CLI to export the profile's current credentials,
// refreshing the SSO token once if it needs it.
//
// The AWS CLI is used rather than a Go SDK for one reason that matters here: it is
// the only implementation that can complete an SSO refresh, and it is already a
// hard requirement of this repository. An empty profile means ambient credentials,
// which the children inherit as they are — there is nothing to resolve and no cache
// to race over.
func ResolveCredentials(ctx context.Context, profile string) (Credentials, error) {
	if profile == "" {
		return Credentials{}, nil
	}

	command := exec.CommandContext(ctx, "aws", "configure", "export-credentials",
		"--profile", profile, "--format", "env-no-export")
	output, err := command.CombinedOutput()
	if err != nil {
		return Credentials{}, fmt.Errorf("infra: cannot resolve credentials for profile %q: %w\n%s\n\n"+
			"An expired SSO session is the usual cause:\n  aws sso login --profile %s",
			profile, err, strings.TrimSpace(string(output)), profile)
	}

	var credentials Credentials
	for _, line := range strings.Split(string(output), "\n") {
		key, value, found := strings.Cut(strings.TrimSpace(line), "=")
		if !found {
			continue
		}
		switch key {
		case "AWS_ACCESS_KEY_ID":
			credentials.AccessKeyID = value
		case "AWS_SECRET_ACCESS_KEY":
			credentials.SecretAccessKey = value
		case "AWS_SESSION_TOKEN":
			credentials.SessionToken = value
		}
	}
	if credentials.AccessKeyID == "" {
		return Credentials{}, fmt.Errorf(
			"infra: profile %q produced no credentials\n"+
				"  aws configure export-credentials --profile %s --format env-no-export",
			profile, profile)
	}
	return credentials, nil
}
