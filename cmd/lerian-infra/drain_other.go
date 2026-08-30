//go:build !linux && !darwin && !freebsd && !netbsd && !openbsd && !dragonfly

package main

// drainStdin is a no-op where this package has no way to flush the terminal's
// input queue. The confirmation still works; it is just answerable by a keystroke
// that arrived before the prompt.
func drainStdin() {}
