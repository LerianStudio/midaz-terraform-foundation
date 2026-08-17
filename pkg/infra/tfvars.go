package infra

import (
	"bufio"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

// placeholderPattern matches the tokens the committed templates leave behind for
// the operator to replace. The second alternative catches a bare <SHOUTING> token
// that the first one's vocabulary does not know about.
var placeholderPattern = regexp.MustCompile(
	`<(PUT-YOUR|YOUR|SEU|seu|CHANGE-ME|CHANGEME|REPLACE)[^>]*>|<[A-Z][A-Z0-9_-]{3,}>`)

// Readiness says whether one root can be planned in this environment.
type Readiness struct {
	Unit Unit
	// Problem is empty when the root is ready, and otherwise one operator-facing
	// line saying what is missing.
	Problem string
	// Remediation is what to do about Problem.
	Remediation string
}

// Ready reports whether the root can run.
func (r Readiness) Ready() bool { return r.Problem == "" }

// VarFile is <root>/envs/<env>.tfvars, the only variables file a stack reads.
func VarFile(unit Unit, env string) string {
	return filepath.Join(unit.Dir, "envs", env+".tfvars")
}

// CheckReadiness verifies that every unit has its envs/<env>.tfvars and that no
// placeholder survives in it.
//
// It returns one entry per unit rather than stopping at the first problem: an
// operator setting up an environment wants the whole list of files to copy, not
// one of them at a time.
//
// Read-only actions do not call this. They never pass -var-file, so the variables
// file is irrelevant to them, and demanding it would block reading the outputs of
// a stack somebody else applied.
func CheckReadiness(units []Unit, env string) []Readiness {
	report := make([]Readiness, 0, len(units))
	for _, unit := range units {
		report = append(report, checkUnitReadiness(unit, env))
	}
	return report
}

func checkUnitReadiness(unit Unit, env string) Readiness {
	path := VarFile(unit, env)
	example := path + "-example"

	if _, err := os.Stat(path); err != nil {
		if _, exampleErr := os.Stat(example); exampleErr == nil {
			return Readiness{
				Unit:    unit,
				Problem: fmt.Sprintf("falta envs/%s.tfvars", env),
				Remediation: fmt.Sprintf("*.tfvars é gitignored e *.tfvars-example é o template versionado:\n"+
					"  cp %s \\\n     %s\n  $EDITOR %s", example, path, path),
			}
		}
		return Readiness{
			Unit:    unit,
			Problem: fmt.Sprintf("falta envs/%s.tfvars e não há %s.tfvars-example", env, env),
			Remediation: fmt.Sprintf("Este stack pode ainda não suportar o ambiente '%s'. "+
				"Veja o que existe em %s.", env, filepath.Join(unit.Dir, "envs")),
		}
	}

	lines, err := placeholderLines(path)
	if err != nil {
		return Readiness{
			Unit:        unit,
			Problem:     fmt.Sprintf("não consegui ler envs/%s.tfvars: %v", env, err),
			Remediation: "Confirme as permissões do arquivo.",
		}
	}
	if len(lines) > 0 {
		return Readiness{
			Unit: unit,
			Problem: fmt.Sprintf("placeholder(s) não resolvido(s) em %d linha(s) de envs/%s.tfvars",
				len(lines), env),
			Remediation: "Substitua cada token <...> por um valor real antes de aplicar:\n  " +
				strings.Join(lines, "\n  "),
		}
	}
	return Readiness{Unit: unit}
}

// placeholderLines returns the numbered lines that still carry a placeholder.
// Comments are stripped first: the committed templates legitimately write things
// like "<that address>" in prose, and a real tfvars keeps those comments.
func placeholderLines(path string) ([]string, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer func() { _ = file.Close() }()

	var found []string
	scanner := bufio.NewScanner(file)
	for number := 1; scanner.Scan(); number++ {
		line := scanner.Text()
		if strings.HasPrefix(strings.TrimSpace(line), "#") {
			continue
		}
		if placeholderPattern.MatchString(line) {
			found = append(found, fmt.Sprintf("%d: %s", number, strings.TrimSpace(line)))
		}
	}
	if err := scanner.Err(); err != nil {
		return nil, err
	}
	return found, nil
}
