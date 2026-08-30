//go:build darwin || freebsd || netbsd || openbsd || dragonfly

package main

import (
	"os"

	"golang.org/x/sys/unix"
)

// drainStdin discards anything typed before the prompt was printed.
//
// Without it, a confirmation is answered by whatever the operator happened to
// press during the long wait before it. That really happened: three stray Enters
// during a sixteen-minute EKS apply were still queued when the next prompt
// appeared, and they declined it instantly — the prompt and the "not confirmed"
// lines landed on the same line of output.
//
// The dangerous version of the same accident is the one that did not happen: a
// queued "yes" would have approved a spend the operator never read. So this
// discards rather than re-prompts.
//
// It flushes the terminal's input queue rather than toggling O_NONBLOCK on the
// descriptor: the shell shares this descriptor, and a process that dies between
// setting and restoring that flag leaves the shell with a non-blocking stdin.
//
// Best effort by design. When stdin is not a terminal there is nothing to flush
// and the error is the answer.
func drainStdin() {
	// FREAD (1) from <sys/fcntl.h>: discard the input queue, leave output alone.
	_ = unix.IoctlSetPointerInt(int(os.Stdin.Fd()), unix.TIOCFLUSH, 1)
}
