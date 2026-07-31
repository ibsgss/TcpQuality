// Package render reproduces the terminal (TUI) tables, summaries and progress
// bars of the original script, including CJK-aware column alignment.
package render

import "strings"

// DisplayWidth returns the terminal column width of s, counting non-ASCII runes
// (CJK) as 2 columns, matching speedtest_display_width / the awk display_width
// helpers in the script.
func DisplayWidth(s string) int {
	w := 0
	for _, r := range s {
		switch {
		case r < 128:
			w++
		case r == '✓' || r == '✗':
			// The script explicitly aligns these status marks as width 1.
			w++
		default:
			w += 2
		}
	}
	return w
}

func spaces(n int) string {
	if n <= 0 {
		return ""
	}
	return strings.Repeat(" ", n)
}

// RJust right-justifies s to display width w (pads on the left), like awk %Ns.
func RJust(s string, w int) string {
	return spaces(w-DisplayWidth(s)) + s
}

// LJust left-justifies s to display width w (pads on the right), like awk %-Ns.
func LJust(s string, w int) string {
	return s + spaces(w-DisplayWidth(s))
}

// Center centers s within display width w.
func Center(s string, w int) string {
	pad := w - DisplayWidth(s)
	if pad < 0 {
		pad = 0
	}
	left := pad / 2
	right := pad - left
	return spaces(left) + s + spaces(right)
}

// sep returns a run of w dashes.
func sep(w int) string {
	if w <= 0 {
		return ""
	}
	return strings.Repeat("-", w)
}
