package infra

import (
	"bufio"
	"errors"
	"fmt"
	"io"
	"os"
	"strings"
)

// EnvConfig is the [<env>] section of environments.conf: which AWS account this
// environment is allowed to touch, and with which credentials.
type EnvConfig struct {
	// Environment is the section name.
	Environment string
	// AccountID is exactly twelve digits and is the whole point of the file: the
	// account the credentials MUST resolve to before anything runs.
	AccountID string
	// Region is cross-checked against backend/<env>.hcl. It is not injected into
	// Terraform — every stack takes its region from envs/<env>.tfvars — so it exists
	// only to catch a disagreement between the places a region is written.
	Region string
	// Profile is a named profile from ~/.aws/config, exported as AWS_PROFILE. Empty
	// means ambient credentials (environment variables, EC2/ECS/IRSA role), which is
	// the CI shape. The account check runs either way.
	Profile string
}

// ErrNoConfigFile is returned when environments.conf does not exist, which is the
// first run of a fresh clone and has its own instruction.
var ErrNoConfigFile = errors.New("infra: environments.conf not found")

// LoadEnvConfig reads the [env] section of environments.conf and validates it.
//
// Every failure here is a failure the operator can fix in a file they can diff,
// which is deliberate: the alternative to this file is a command-line flag that
// says "yes, prd really is that account", typed at the end of a long day.
func LoadEnvConfig(layout Layout, env string) (EnvConfig, error) {
	path := layout.ConfigFile()

	file, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return EnvConfig{}, fmt.Errorf("%w: %s\n"+
				"This file maps each environment to the AWS account it is allowed to touch.\n"+
				"Without it there is no way to verify that '%s' points at the right account.\n\n"+
				"  cp %s \\\n     %s\n  $EDITOR %s\n\n"+
				"A single AWS account for all three environments is supported: give dev, stg\n"+
				"and prd the same account_id and profile.",
				ErrNoConfigFile, layout.RepoRel(path), env,
				layout.RepoRel(layout.ConfigExample()), layout.RepoRel(path), layout.RepoRel(path))
		}
		return EnvConfig{}, fmt.Errorf("infra: cannot read %s: %w", layout.RepoRel(path), err)
	}
	defer func() { _ = file.Close() }()

	sections, err := parseINI(file)
	if err != nil {
		return EnvConfig{}, fmt.Errorf("infra: cannot read %s: %w", layout.RepoRel(path), err)
	}

	values, ok := sections[env]
	if !ok {
		return EnvConfig{}, fmt.Errorf("infra: no [%s] section in %s\n"+
			"Add one:\n\n  [%s]\n  account_id = 123456789012\n  profile    = your-aws-profile\n"+
			"  region     = us-east-2\n\n"+
			"profile may be left empty to use ambient credentials (CI, IRSA).",
			env, layout.RepoRel(path), env)
	}

	config := EnvConfig{
		Environment: env,
		AccountID:   values["account_id"],
		Region:      values["region"],
		Profile:     values["profile"],
	}
	// "-" is the explicit spelling of "no profile", for a config that wants to say
	// so out loud instead of leaving the value blank.
	if config.Profile == "-" {
		config.Profile = ""
	}

	if err := config.validate(layout.RepoRel(path)); err != nil {
		return EnvConfig{}, err
	}
	return config, nil
}

func (c EnvConfig) validate(configPath string) error {
	if c.AccountID == "" {
		return fmt.Errorf("infra: [%s] in %s has no account_id\n"+
			"account_id is the account the credentials must resolve to before anything runs.\n"+
			"Find it with:  aws sts get-caller-identity --query Account --output text",
			c.Environment, configPath)
	}
	if !isTwelveDigits(c.AccountID) {
		return fmt.Errorf("infra: invalid account_id for [%s] in %s: %q\n"+
			"An AWS account id is exactly 12 digits, no dashes and no quotes.",
			c.Environment, configPath, c.AccountID)
	}
	if c.Region == "" {
		return fmt.Errorf("infra: [%s] in %s has no region\n"+
			"Add:  region = us-east-2\n"+
			"It is cross-checked against the region in backend/%s.hcl.",
			c.Environment, configPath, c.Environment)
	}
	return nil
}

func isTwelveDigits(value string) bool {
	if len(value) != 12 {
		return false
	}
	for _, r := range value {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// parseINI reads the sectioned key = value format of environments.conf. Comments
// start with '#', anywhere on a line, and whitespace around keys and values is
// insignificant.
//
// The first occurrence of a key inside a section wins, matching the awk the shell
// version used: a duplicated key is a mistake, and taking the first one makes the
// mistake visible in the same order the file reads.
func parseINI(reader io.Reader) (map[string]map[string]string, error) {
	sections := map[string]map[string]string{}
	current := ""

	scanner := bufio.NewScanner(reader)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "[") {
			end := strings.Index(line, "]")
			if end < 0 {
				continue
			}
			current = strings.TrimSpace(line[1:end])
			if _, ok := sections[current]; !ok {
				sections[current] = map[string]string{}
			}
			continue
		}
		if current == "" {
			continue
		}
		separator := strings.Index(line, "=")
		if separator < 0 {
			continue
		}
		key := strings.TrimSpace(line[:separator])
		value := line[separator+1:]
		if comment := strings.Index(value, "#"); comment >= 0 {
			value = value[:comment]
		}
		value = strings.TrimSpace(value)
		if _, seen := sections[current][key]; !seen {
			sections[current][key] = value
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return sections, nil
}
