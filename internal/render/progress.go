package render

import (
	"fmt"
	"strings"
)

// Bar renders a fixed-width progress bar: "[####----] done/total (pct%)".
func Bar(done, total int) string {
	const width = 40
	if total <= 0 {
		total = 1
	}
	if done > total {
		done = total
	}
	pct := done * 100 / total
	fill := done * width / total
	empty := width - fill
	return fmt.Sprintf("[%s%s] %d/%d (%d%%)",
		strings.Repeat("#", fill), strings.Repeat("-", empty), done, total, pct)
}

// Header renders the two-line banner printed at the top of a run.
func Header() string {
	var b strings.Builder
	fmt.Fprintf(&b, "%s%sTcpQuality TCP 重传检测--最贴近你上网的综合体验%s\n", bold, cyan, nc)
	fmt.Fprintf(&b, "%s特价VPS补货TG频道：ibsgss | 感谢 Zstatic CDN 节点%s\n", dim, nc)
	fmt.Fprintf(&b, "%s------------------------------------------------------------%s\n", dim, nc)
	return b.String()
}
