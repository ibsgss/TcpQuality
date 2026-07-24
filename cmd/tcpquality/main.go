// Command tcpquality is a native-Go port of runTcpQuality.sh: it probes TCP
// SYN loss/latency to three-carrier nodes in China, identifies backbone return
// routes, measures international connectivity, and runs staged speedtests.
package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"tcpquality/internal/app"
	"tcpquality/internal/config"
)

func main() {
	cfg := config.New()
	if err := cfg.ParseArgs(os.Args[1:]); err != nil {
		if errors.Is(err, config.ErrHelp) {
			fmt.Print(config.HelpText())
			return
		}
		fmt.Fprintf(os.Stderr, "%s[X] %v%s\n", config.Red, err, config.NC)
		fmt.Fprintln(os.Stderr, "使用 -h 或 --help 查看帮助。")
		os.Exit(1)
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if err := app.New(cfg).Run(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "%s[X] %v%s\n", config.Red, err, config.NC)
		os.Exit(1)
	}
}
