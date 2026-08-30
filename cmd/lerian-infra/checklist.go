package main

import (
	"fmt"
	"io"
	"strings"
	"sync"

	"github.com/LerianStudio/lerian-terraform-foundation/pkg/infra"
)

// checklist renders a run as it happens, as a tree of stages.
//
// It is deliberately not a repainting TUI. The units of a stage run in parallel
// and the output is routinely piped into a file or a CI log, where cursor movement
// produces garbage; an append-only log of what happened reads correctly in both
// places.
//
// The tree shape carries information the flat list did not: which stacks belong to
// the same stage, and therefore which ran together and which waited. A stage is
// also where the ordering guarantee lives, so making it visible makes the run's
// structure legible without reading the docs.
type checklist struct {
	mu  sync.Mutex
	out io.Writer

	// stages is the structure the tree draws, in execution order.
	stages []stageView
	// index finds a unit's stage in O(1); units are unique across a run.
	index map[string]int
	// width is the label column, sized to the longest short name so no line is
	// padded to an arbitrary constant.
	width int
	// style decides whether headings may be emphasised.
	style style
	// spin is the in-flight repaint, nil when the destination is not a terminal.
	spin *spinner
	// opened records that a stage header has already been written, so only the
	// first one adds the blank line separating the tree from the preflight; every
	// later stage is already preceded by the blank line its predecessor's last
	// phase emitted.
	opened bool
}

type stageView struct {
	name  string
	units []string
	// printed is whether the stage header has already been written.
	printed bool
	// done counts completions in the current phase. It resets when the stage
	// completes, so the plan phase and the apply phase each close with a "last"
	// connector instead of the second phase drawing all of them as intermediate.
	done int
	// number is this stage's 1-based position, for the [n/total] marker.
	number int
	// running guards the one in-flight line per phase; it clears with done.
	running bool
}

// newChecklist builds the renderer for a known set of stages.
//
// The Progress interface carries only unit names, on purpose: it is the contract
// the wizard implements too, and a graphical checklist has no use for connectors.
// The tree is a property of this terminal renderer, so the structure is passed
// here rather than pushed into the shared interface.
func newChecklist(out io.Writer, stages []infra.Stage) *checklist {
	c := &checklist{out: out, index: map[string]int{}, style: newStyle(out)}

	for i, stage := range stages {
		view := stageView{name: stage.Name, number: i + 1}
		for _, unit := range stage.Units {
			view.units = append(view.units, unit.Name)
			c.index[unit.Name] = i
			if n := len(shortName(stage.Name, unit.Name)); n > c.width {
				c.width = n
			}
		}
		c.stages = append(c.stages, view)
	}
	// A floor keeps short runs from looking cramped; a ceiling keeps one long
	// product name from pushing the results off an 80-column terminal.
	if c.width < 12 {
		c.width = 12
	}
	if c.width > 34 {
		c.width = 34
	}
	return c
}

// shortName drops the part of a unit's name its stage header already shows.
//
// Under "[3/3] midaz", a row reading "products/midaz/documentdb" spends most of
// its width repeating the heading above it.
func shortName(stage, unit string) string {
	if unit == stage {
		// Single-unit stages (infra-base/vpc) name themselves; the leaf keeps only
		// the last segment so the row does not restate the header verbatim.
		if index := strings.LastIndex(unit, "/"); index >= 0 {
			return unit[index+1:]
		}
		return unit
	}
	if trimmed := strings.TrimPrefix(unit, "products/"+stage+"/"); trimmed != unit {
		return trimmed
	}
	if index := strings.LastIndex(unit, "/"); index >= 0 {
		return unit[index+1:]
	}
	return unit
}

func (c *checklist) Start([]string) {}

func (c *checklist) Update(unit string, status infra.Status, detail, remediation string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	c.spin.erase()

	position, known := c.index[unit]
	if !known {
		// A unit the renderer was not told about still has to be visible.
		fmt.Fprintf(c.out, "     %-*s  %s\n", c.width, unit, detail)
		return
	}
	stage := &c.stages[position]

	if !stage.printed {
		stage.printed = true
		header := fmt.Sprintf("  [%d/%d] %s", stage.number, len(c.stages), stage.name)
		if len(stage.units) > 1 {
			// Worth stating: it explains why four things move at once, and why the
			// wall-clock is the slowest of them rather than their sum.
			header += strings.Repeat(" ", maxInt(2, 47-len(header))) +
				fmt.Sprintf("%d in parallel", len(stage.units))
		}
		if !c.opened {
			fmt.Fprintln(c.out)
			c.opened = true
		}
		fmt.Fprintf(c.out, "%s\n", c.style.bold(header))
	}

	label := shortName(stage.name, unit)

	if status == infra.StatusPending {
		return
	}
	if status == infra.StatusRunning {
		// One line per stage per phase, not one per unit. In a stage of four running
		// together, four "planning..." lines say the same thing four times, and once
		// results start arriving the tree already shows which stacks are still out.
		// No connector either: this line is superseded and must not read as a
		// finished branch.
		if stage.running {
			return
		}
		stage.running = true

		label := strings.TrimSuffix(detail, "...")
		if len(stage.units) > 1 {
			label = fmt.Sprintf("%s %d stacks", label, len(stage.units))
		}
		if c.style.enabled {
			c.spin = newSpinner(&c.mu, c.out, label)
			return
		}
		fmt.Fprintf(c.out, "     %s\n", c.style.dim("·  "+label))
		return
	}

	stage.done++
	phaseEnded := false
	connector := "├─"
	if stage.done >= len(stage.units) {
		connector = "└─"
		// Reset so the apply phase draws its own closing branch, and its own
		// in-flight line, rather than continuing the plan phase's state.
		stage.done = 0
		stage.running = false
		phaseEnded = true
	}

	mark := map[infra.Status]string{
		infra.StatusOK:      "ok",
		infra.StatusWarn:    "warn",
		infra.StatusSkipped: "--",
		infra.StatusFail:    "FAIL",
	}[status]

	// pkg/infra separates the outcome from its timing with a tab so it can be
	// column-aligned here. Text without one simply has no timing column.
	text, elapsed, _ := strings.Cut(firstLine(detail), "\t")
	fmt.Fprintf(c.out, "     %s %-*s  %-30s %9s  %s\n",
		connector, c.width, label, text, elapsed, mark)

	if remediation != "" {
		fmt.Fprintf(c.out, "        %s\n", indent(remediation, "        "))
	}

	if phaseEnded {
		// The stage is done with this phase. Stopping the spinner here is what lets
		// the confirmation that follows own the terminal, and the blank line is what
		// keeps that question from being glued to the last branch of the tree.
		if c.spin != nil {
			spin := c.spin
			c.spin = nil
			c.mu.Unlock()
			spin.Stop()
			c.mu.Lock()
		}
		fmt.Fprintln(c.out)
	}
}

func (c *checklist) Finish(bool) {}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}

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
