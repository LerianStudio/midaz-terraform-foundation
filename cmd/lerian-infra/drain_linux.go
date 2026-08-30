//go:build linux

package main

import (
	"os"

	"golang.org/x/sys/unix"
)

// drainStdin discards anything typed before the prompt was printed. See
// drain_bsd.go for why this exists; Linux spells the same flush differently.
func drainStdin() {
	_ = unix.IoctlSetInt(int(os.Stdin.Fd()), unix.TCFLSH, unix.TCIFLUSH)
}
