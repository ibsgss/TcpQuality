package app

import (
	"context"
	"strconv"
	"sync"
	"sync/atomic"

	"tcpquality/internal/config"
	"tcpquality/internal/nodes"
	"tcpquality/internal/probe"
	"tcpquality/internal/render"
)

func portOr(s string, def int) int {
	if n, err := strconv.Atoi(s); err == nil && n > 0 {
		return n
	}
	return def
}

// testOne probes a node's primary endpoint and, when warranted, its backup,
// then merges per test_one.
func testOne(ctx context.Context, p *probe.Prober, n nodes.Node, defPort int) probe.Result {
	primary := p.ProbeTarget(ctx, n.Province, n.ISP, n.Host, n.IP, portOr(n.Port, defPort))
	if n.BackupIP != "" && probe.ShouldProbeBackup(primary) {
		backup := p.ProbeTarget(ctx, n.Province, n.ISP, n.BackupHost, n.BackupIP, portOr(n.BackupPort, defPort))
		return probe.DecideWithBackup(primary, backup)
	}
	return primary
}

// probeNodes probes every node with the configured parallelism, returning
// results in input order and reporting progress via onProgress.
func (a *App) probeNodes(ctx context.Context, p *probe.Prober, list []nodes.Node, defPort int, onDone func()) []probe.Result {
	results := make([]probe.Result, len(list))
	runPool(len(list), a.cfg.Parallel, func(i int) {
		results[i] = testOne(ctx, p, list[i], defPort)
		if onDone != nil {
			onDone()
		}
	})
	return results
}

// filterNodes keeps only nodes whose province passes the active filter.
func (a *App) filterNodes(list []nodes.Node) []nodes.Node {
	out := make([]nodes.Node, 0, len(list))
	for _, n := range list {
		if a.cfg.ProvinceSelected(n.Province) {
			out = append(out, n)
		}
	}
	return out
}

// runPool runs worker(i) for i in [0,n) with the given parallelism.
func runPool(n, parallel int, worker func(i int)) {
	if parallel < 1 {
		parallel = 1
	}
	sem := make(chan struct{}, parallel)
	var wg sync.WaitGroup
	for i := 0; i < n; i++ {
		wg.Add(1)
		sem <- struct{}{}
		go func(idx int) {
			defer wg.Done()
			defer func() { <-sem }()
			worker(idx)
		}(i)
	}
	wg.Wait()
}

// progressCounter tracks completed work and renders a single-line bar.
type progressCounter struct {
	app   *App
	label string
	total int
	done  int64
}

func (a *App) newProgress(label string, total int) *progressCounter {
	pc := &progressCounter{app: a, label: label, total: total}
	pc.render()
	return pc
}

func (pc *progressCounter) inc() {
	atomic.AddInt64(&pc.done, 1)
	pc.render()
}

func (pc *progressCounter) setDone(done int) {
	atomic.StoreInt64(&pc.done, int64(done))
	pc.render()
}

func (pc *progressCounter) render() {
	done := int(atomic.LoadInt64(&pc.done))
	pc.app.printf("\r  %s%s%s %s   ", config.Cyan, pc.label, config.NC, render.Bar(done, pc.total))
}

func (pc *progressCounter) finish() {
	pc.app.print("\n")
}
