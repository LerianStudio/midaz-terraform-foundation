package main

// prompter is the entire interactive layer, and it is deliberately thin.
//
// It holds no decisions of its own: every question it asks corresponds to a flag,
// and when there is no terminal it refuses by naming that flag instead of guessing.
// That is what keeps the two front ends honest — a graphical client that never sees
// this file can still reach every capability, because the capability lives in
// pkg/infra and the flag, not in the question.

import (
	"bufio"
	"fmt"
	"io"
	"os"
	"strings"
	"text/tabwriter"

	"golang.org/x/term"

	"github.com/LerianStudio/lerian-terraform-foundation/pkg/infra"
)

type prompter struct {
	interactive bool
	in          *bufio.Reader
	out         io.Writer
}

// newPrompter returns a prompter that asks only when stdin is a terminal.
func newPrompter(out io.Writer) *prompter {
	return &prompter{
		interactive: isTerminal(os.Stdin),
		in:          bufio.NewReader(os.Stdin),
		out:         out,
	}
}

// isTerminal reports whether a human can answer on f.
//
// This is a real isatty, not a check for a character device: /dev/null is a
// character device too, so `init </dev/null` in CI would have been mistaken for an
// interactive session and asked questions nobody was there to answer. The shell
// spelling of this same test, `[ -t 0 ]`, is what deploy.sh used to use.
func isTerminal(f *os.File) bool {
	return term.IsTerminal(int(f.Fd()))
}

// text asks for a value with no explanation. Prefer ask: a bare question assumes
// the reader already knows why it is being asked, and the people running this are
// often meeting this infrastructure for the first time.
func (p *prompter) text(question, fallback, flagName string) (string, error) {
	return p.ask(question, "", fallback, flagName)
}

// ask puts a question with its purpose.
//
// The shape is fixed on purpose: the question in bold on its own line, one line of
// plain prose saying what the answer decides, then the input on the line below.
// Question and input on the same line works for someone who already knows the
// tool; it reads as a demand for a password to everyone else, and this CLI is
// meant to be usable by somebody touching Terraform for the first time.
func (p *prompter) ask(question, purpose, fallback, flagName string) (string, error) {
	if !p.interactive {
		if fallback != "" {
			return fallback, nil
		}
		return "", fmt.Errorf("%s is required and there is no terminal to ask\n"+
			"Pass %s explicitly.", question, flagName)
	}

	theme := newStyle(p.out)
	fmt.Fprintf(p.out, "\n  %s\n", theme.bold(question))
	if purpose != "" {
		fmt.Fprintf(p.out, "  %s\n", theme.dim(purpose))
	}
	if fallback != "" {
		fmt.Fprintf(p.out, "  > [%s] ", fallback)
	} else {
		fmt.Fprint(p.out, "  > ")
	}

	line, err := p.in.ReadString('\n')
	if err != nil && strings.TrimSpace(line) == "" {
		return "", fmt.Errorf("cannot read the answer to %q: %w", question, err)
	}
	answer := strings.TrimSpace(line)
	if answer == "" {
		if fallback == "" {
			return "", fmt.Errorf("%s is required", question)
		}
		return fallback, nil
	}
	return answer, nil
}

// confirm requires the word "yes", the same bar the apply confirmation uses.
func (p *prompter) confirm(errOut io.Writer, question string) error {
	if !p.interactive {
		return fmt.Errorf("this needs a confirmation but stdin is not a terminal\n"+
			"Pending: %s\n\n"+
			"Re-run from a terminal, or pass --auto-approve. The list above is exactly\n"+
			"what would be written.", question)
	}
	// Discard anything queued before the question. Unlike the prompts above, where
	// typing ahead through a known sequence is legitimate, this one guards a write
	// and must be answered deliberately.
	//
	// p.in has its own buffer, so it is rebuilt after the flush: bytes already
	// pulled out of the descriptor are beyond the reach of a terminal ioctl.
	drainStdin()
	p.in = bufio.NewReader(os.Stdin)

	fmt.Fprintf(p.out, "\n  %s [type yes to continue]: ", question)
	line, err := p.in.ReadString('\n')
	if err != nil && strings.TrimSpace(line) == "" {
		return fmt.Errorf("cannot read the confirmation: %w", err)
	}
	if strings.TrimSpace(line) != "yes" {
		fmt.Fprintln(errOut)
		return infra.ErrAborted
	}
	return nil
}

// printProfiles shows what each profile reaches, which is the question an operator
// actually has: not "which profiles exist" but "which one is the right account".
func (p *prompter) printProfiles(resolved []infra.ResolvedProfile) {
	if !p.interactive {
		return
	}
	fmt.Fprintf(p.out, "\n%s\n\n", newStyle(p.out).bold("==> AWS profiles"))
	writer := tabwriter.NewWriter(p.out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(writer, "  PROFILE\tACCOUNT\tREGION\tSTATUS")

	failed := 0
	for _, entry := range resolved {
		account, status := "-", "ok"
		if !entry.Usable() {
			// The per-row status stays short. Repeating the remedy on every row turns
			// a dozen profiles behind one expired SSO session into a dozen lines that
			// each look like a separate problem; the fix is printed once, below.
			status = "expired"
			failed++
		} else {
			account = entry.Caller.Account
		}
		region := entry.Profile.Region
		if region == "" {
			region = "-"
		}
		fmt.Fprintf(writer, "  %s\t%s\t%s\t%s\n", entry.Profile.Name, account, region, status)
	}
	_ = writer.Flush()

	if hint := infra.LoginHint(resolved); failed > 0 && hint != "" {
		fmt.Fprintf(p.out, "\n  %d profile(s) need a login:\n  %s\n", failed, hint)
	}
	fmt.Fprintln(p.out)
}
