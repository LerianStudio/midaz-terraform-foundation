package main

import (
	"io"
	"os"
)

// style decides whether this run may emit ANSI.
//
// Three conditions, all of which must hold, because the same output is routinely
// redirected: `--action helm-values > values.yaml` must produce a YAML file with
// no escape sequences in it, and a CI log full of colour codes is worse than a
// plain one.
//
//   - the destination is a terminal;
//   - NO_COLOR is unset (https://no-color.org, honoured by convention);
//   - TERM is not "dumb", which is what an editor's shell reports.
type style struct{ enabled bool }

func newStyle(out io.Writer) style {
	file, ok := out.(*os.File)
	if !ok || !isTerminal(file) {
		return style{}
	}
	if _, noColor := os.LookupEnv("NO_COLOR"); noColor {
		return style{}
	}
	if os.Getenv("TERM") == "dumb" {
		return style{}
	}
	return style{enabled: true}
}

// bold marks a section heading. Headings are the only thing emphasised: colour
// used to carry meaning (green for ok, red for fail) reads as decoration once a
// run has forty lines, and it disappears entirely for the readers who need it
// most — colour-blind operators and anyone reading the piped log.
func (s style) bold(text string) string {
	if !s.enabled {
		return text
	}
	return "\x1b[1m" + text + "\x1b[0m"
}

// alert is bold red, and it is the only place colour carries meaning in this tool.
//
// It is reserved for a choice the operator is allowed to make and will own the
// consequences of — shared datastores in production being the case it was added
// for. Everything else that colour could mark (ok, failed, skipped) is already
// spelled out in words, so that a reader without colour, or reading a saved log,
// loses nothing. Here the words are still complete; the colour only makes them
// impossible to scroll past.
func (s style) alert(text string) string {
	if !s.enabled {
		return text
	}
	return "\x1b[1;31m" + text + "\x1b[0m"
}

// dim is for text that is present but should not compete: the in-flight line,
// which is superseded by its own result a moment later.
func (s style) dim(text string) string {
	if !s.enabled {
		return text
	}
	return "\x1b[2m" + text + "\x1b[0m"
}
