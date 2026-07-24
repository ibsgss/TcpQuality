//go:build !linux

package route

import (
	"context"
	"errors"
)

// Trace is unavailable on non-Linux platforms.
func Trace(ctx context.Context, family, protocol, destIP string, port, psize int) (*TraceResult, error) {
	return nil, errors.New("原生 traceroute 目前仅支持 Linux")
}
