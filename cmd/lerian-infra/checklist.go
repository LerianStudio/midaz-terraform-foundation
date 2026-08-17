package main

import (
	"fmt"
	"io"
	"sync"

	"github.com/LerianStudio/lerian-terraform-foundation/pkg/infra"
)

// checklist renders a run as it happens, one line per transition.
//
// It is deliberately not a repainting TUI. The units of a stage run in parallel
// and the output is routinely piped into a file or a CI log, where cursor
// movement produces garbage; an append-only log of what happened reads correctly
// in both places.
type checklist struct {
	mu  sync.Mutex
	out io.Writer

	total int
	done  int
}

func newChecklist(out io.Writer) *checklist { return &checklist{out: out} }

func (c *checklist) Start(units []string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.total = len(units)
	c.done = 0
	fmt.Fprintf(c.out, "\n==> %d stack(s)\n", c.total)
}

func (c *checklist) Update(unit string, status infra.Status, detail, remediation string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	switch status {
	case infra.StatusRunning:
		fmt.Fprintf(c.out, "  ... %-44s %s\n", unit, detail)
		return
	case infra.StatusOK:
		c.done++
		fmt.Fprintf(c.out, "  ok  %-44s %s\n", unit, detail)
	case infra.StatusWarn:
		fmt.Fprintf(c.out, "  warn %-43s %s\n", unit, detail)
	case infra.StatusSkipped:
		fmt.Fprintf(c.out, "  --  %-44s %s\n", unit, detail)
	case infra.StatusFail:
		fmt.Fprintf(c.out, "  FAIL %-43s %s\n", unit, firstLine(detail))
	case infra.StatusPending:
		return
	}
	if remediation != "" {
		fmt.Fprintf(c.out, "      %s\n", indent(remediation, "      "))
	}
}

func (c *checklist) Finish(bool) {}

// firstLine keeps the per-unit line to one line. The full error is printed once,
// in full, after the run.
func firstLine(text string) string {
	for i := 0; i < len(text); i++ {
		if text[i] == '\n' {
			return text[:i]
		}
	}
	return text
}
