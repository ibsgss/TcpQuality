//go:build !linux

package speedtest

import (
	"context"
	"errors"

	"tcpquality/internal/nodes"
)

// Run is unsupported off Linux (tc/ifb rate limiting and /sys counters).
func Run(ctx context.Context, opts Options, tos []nodes.SpeedtestNode, onProgress func(done, total int)) (*Results, error) {
	return nil, errors.New("国内三网单线程测速目前仅支持 Linux")
}
