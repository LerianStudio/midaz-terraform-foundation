package main

import (
	"fmt"
	"io"
	"os"
	"sync"
	"time"
	"unicode/utf8"
)

// spinner repaints a single in-flight line with a running clock.
//
// It exists for one reason: the apply of a stage takes minutes with nothing to
// print in between — sixteen for EKS, nine for the midaz datastores — and a
// terminal that has said nothing for nine minutes is indistinguishable from one
// that has hung. The elapsed counter is the part that carries the information;
// the turning character only proves the process is alive.
//
// It repaints, so it runs only on a terminal. Everywhere else — a redirected
// file, a CI log — the static line printed before it is the whole output, and no
// carriage returns are emitted at all.
type spinner struct {
	// mu is the checklist's mutex, shared rather than owned: the ticking
	// goroutine and the result lines write to the same descriptor, and a frame
	// painted between the two halves of a result line would corrupt both.
	mu  *sync.Mutex
	out io.Writer

	label   string
	started time.Time
	frames  []rune
	stop    chan struct{}
	done    chan struct{}
	// painted records whether the current line holds a frame that must be erased
	// before anything else is written.
	painted bool
	// inert marks a spinner on a destination that cannot repaint. It paints nothing
	// and erases nothing.
	inert bool
}

// brailleFrames is the dot_cycle from the gist this was modelled on: a 2x4 braille
// cell with the filled dots rotating, which reads as continuous motion rather than
// a character being swapped.
//
// It needs a font covering U+2800-U+28FF. That is nearly universal on developer
// machines and much less certain over ssh to a minimal server or inside a CI web
// UI, so LERIAN_SPINNER=ascii falls back without a rebuild.
var brailleFrames = []rune{'⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷'}

// asciiFrames is the fallback for anywhere the braille block is not rendered.
var asciiFrames = []rune{'|', '/', '-', '\\'}

// spinnerFrames picks the set for this run.
func spinnerFrames() []rune {
	if os.Getenv("LERIAN_SPINNER") == "ascii" {
		return asciiFrames
	}
	return brailleFrames
}

// newSpinner returns a live spinner on a terminal and an inert one everywhere else.
//
// The "only on a terminal" rule is enforced HERE rather than left to each caller.
// It used to be a documented invariant every call site had to remember, and the
// second call site forgot it: piping the output produced every frame on its own
// line, which in a CI log is hundreds of lines of carriage-return debris around the
// one line that mattered. A rule that has to be re-remembered per caller is a bug
// with a delay on it, so the constructor now refuses to animate what cannot repaint.
//
// An inert spinner is returned rather than nil so callers need no branch and no nil
// check; Stop on it does nothing.
func newSpinner(mu *sync.Mutex, out io.Writer, label string) *spinner {
	s := &spinner{
		mu:      mu,
		out:     out,
		label:   label,
		started: time.Now(),
		frames:  spinnerFrames(),
		stop:    make(chan struct{}),
		done:    make(chan struct{}),
	}
	// Same three conditions the colour decision uses: a terminal, NO_COLOR unset,
	// and TERM not "dumb". Anything that cannot take ANSI cannot take a repaint.
	if !newStyle(out).enabled {
		s.inert = true
		close(s.done)
		return s
	}
	go s.run()
	return s
}

func (s *spinner) run() {
	defer close(s.done)

	ticker := time.NewTicker(120 * time.Millisecond)
	defer ticker.Stop()

	for frame := 0; ; frame++ {
		select {
		case <-s.stop:
			return
		case <-ticker.C:
			s.mu.Lock()
			// \r returns to column zero without a newline, so the next frame
			// overwrites this one instead of scrolling.
			fmt.Fprintf(s.out, "\r     %c  %s  %s",
				s.frames[frame%len(s.frames)], s.label, elapsedClock(time.Since(s.started)))
			s.painted = true
			s.mu.Unlock()
		}
	}
}

// erase clears the painted frame. The caller must already hold the mutex, which
// is why this is not exported: it is one half of a write the checklist finishes.
func (s *spinner) erase() {
	if s == nil || !s.painted {
		return
	}
	// Overwrite with blanks rather than an erase sequence: \r plus spaces works on
	// every terminal, including the ones that ignore \x1b[K.
	fmt.Fprintf(s.out, "\r%s\r", spaces(utf8.RuneCountInString(s.label)+28))
	s.painted = false
}

// Stop ends the goroutine and leaves the line clean. Safe on a nil spinner so
// callers do not branch on whether a terminal was detected.
func (s *spinner) Stop() {
	if s == nil {
		return
	}
	// An inert spinner never started the goroutine and never painted, so there is no
	// frame to erase and nothing to wait for. Closing s.stop here would be a second
	// close on a channel nobody reads.
	if s.inert {
		return
	}
	close(s.stop)
	<-s.done

	s.mu.Lock()
	s.erase()
	s.mu.Unlock()
}

// elapsedClock renders m:ss, which stays the same width for the whole run: a
// counter that jumps from "59s" to "1m0s" makes the line twitch.
func elapsedClock(d time.Duration) string {
	total := int(d.Seconds())
	return fmt.Sprintf("%d:%02d", total/60, total%60)
}

func spaces(n int) string {
	if n < 0 {
		n = 0
	}
	out := make([]byte, n)
	for i := range out {
		out[i] = ' '
	}
	return string(out)
}
