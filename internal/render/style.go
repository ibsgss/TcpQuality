package render

import (
	"fmt"

	"tcpquality/internal/config"
)

// Re-export the palette for brevity within this package.
const (
	red    = config.Red
	green  = config.Green
	yellow = config.Yellow
	cyan   = config.Cyan
	white  = config.White
	dim    = config.Dim
	bold   = config.Bold
	nc     = config.NC
)

// compactLoss rounds a loss percentage to the nearest integer (int(v+0.5)).
func compactLoss(v float64) int { return int(v + 0.5) }

// latencyColorSummary matches the summary-table latency coloring.
func latencyColorSummary(v, loss float64) string {
	switch {
	case loss >= 100:
		return red
	case v > 240:
		return red
	case v > 150:
		return yellow
	default:
		return green
	}
}

func latencyText(v, loss float64) string {
	if loss >= 100 {
		return "-1ms"
	}
	return fmt.Sprintf("%.0fms", v)
}

func lossColorSummary(loss float64) string {
	switch {
	case loss > 20:
		return red
	case loss > 0:
		return yellow
	default:
		return green
	}
}
