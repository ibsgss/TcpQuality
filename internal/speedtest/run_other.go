//go:build !linux

package speedtest

import (
	"context"
	"errors"
)

// Run is unsupported off Linux (iptables byte counters, /etc/hosts pinning and
// /proc counters).
func Run(ctx context.Context, opts Options, onProgress func(done, total int)) (*Results, error) {
	return nil, errors.New("单线程测速目前仅支持 Linux")
}
