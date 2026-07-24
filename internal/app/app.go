// Package app wires the individual subsystems together into the top-level run
// flow, mirroring main() in the original script.
package app

import (
	"context"
	"fmt"
	"io"
	"os"
	"time"

	"tcpquality/internal/config"
	"tcpquality/internal/iputil"
	"tcpquality/internal/render"
)

// App holds shared run state.
type App struct {
	cfg   *config.Config
	out   io.Writer
	stack iputil.Stack
}

// New constructs an App for the given configuration.
func New(cfg *config.Config) *App {
	return &App{cfg: cfg, out: os.Stdout}
}

func (a *App) printf(format string, args ...any) { fmt.Fprintf(a.out, format, args...) }
func (a *App) print(s string)                    { fmt.Fprint(a.out, s) }

// iputilDetect probes the public IPv4/IPv6 stack.
func iputilDetect(ctx context.Context) iputil.Stack { return iputil.Detect(ctx) }

// nowReportTime returns the Beijing-time report timestamp string.
func nowReportTime() (full, short string) {
	loc, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		loc = time.FixedZone("CST", 8*3600)
	}
	t := time.Now().In(loc)
	short = t.Format("2006-01-02 15:04:05 CST")
	full = short + "（北京时间）"
	return
}

// Run dispatches to the appropriate mode and executes it.
func (a *App) Run(ctx context.Context) error {
	a.print("\033[2J\033[H") // clear
	a.print(render.Header())

	switch {
	case a.cfg.InternationalOnly:
		if a.cfg.CountExplicit {
			a.cfg.InternationalPackets = a.cfg.Packets
		}
		return a.runInternationalMode(ctx)
	case a.cfg.SpeedtestOnly:
		return a.runSpeedtestMode(ctx)
	case a.cfg.RouteMode:
		return a.runRouteMode(ctx)
	default:
		return a.runMainMode(ctx)
	}
}
