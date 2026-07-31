//go:build !linux

package probe

import "errors"

// newSender returns an error on platforms without raw-socket SYN support.
func newSender(family string) (synSender, error) {
	return nil, errors.New("原生 SYN 探测目前仅支持 Linux")
}
