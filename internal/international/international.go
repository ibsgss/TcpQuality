// Package international performs IPv4 TCP reachability/latency probing against
// well-known overseas sites and CDNs, mirroring the 国际互联 section.
package international

import (
	"context"
	"sync"
	"sync/atomic"

	"tcpquality/internal/iputil"
	"tcpquality/internal/probe"
)

// Target is one international endpoint.
type Target struct {
	Category string // 网站 or CDN
	Name     string
	Domain   string
}

// SiteTargets are the "常用网站" endpoints.
var SiteTargets = []Target{
	{"网站", "Adobe Assets", "assets.adobe.com"},
	{"网站", "Amazon", "www.amazon.com"},
	{"网站", "Apple iCloud", "www.icloud.com"},
	{"网站", "AWS STS", "sts.amazonaws.com"},
	{"网站", "ChatGPT", "chatgpt.com"},
	{"网站", "Claude", "claude.ai"},
	{"网站", "Cloudflare Dashboard", "dash.cloudflare.com"},
	{"网站", "Discord Gateway", "gateway.discord.gg"},
	{"网站", "Dropbox API", "api.dropboxapi.com"},
	{"网站", "Facebook", "www.facebook.com"},
	{"网站", "GitHub API", "api.github.com"},
	{"网站", "GitLab", "gitlab.com"},
	{"网站", "Gmail", "mail.google.com"},
	{"网站", "Google Search", "www.google.com"},
	{"网站", "Google Static", "www.gstatic.com"},
	{"网站", "Instagram", "www.instagram.com"},
	{"网站", "Microsoft Login", "login.microsoftonline.com"},
	{"网站", "Netflix API", "api-global.netflix.com"},
	{"网站", "NodeSeek", "www.nodeseek.com"},
	{"网站", "Notion API", "api.notion.com"},
	{"网站", "OpenAI API", "api.openai.com"},
	{"网站", "PayPal API", "api-m.paypal.com"},
	{"网站", "Reddit OAuth", "oauth.reddit.com"},
	{"网站", "Slack App", "app.slack.com"},
	{"网站", "Spotify Web", "open.spotify.com"},
	{"网站", "Steam", "store.steampowered.com"},
	{"网站", "Telegram", "telegram.org"},
	{"网站", "Wikipedia", "www.wikipedia.org"},
	{"网站", "X", "x.com"},
	{"网站", "YouTube API", "youtubei.googleapis.com"},
	{"网站", "Zoom API", "api.zoom.us"},
}

// CDNTargets are the "常用 CDN" endpoints.
var CDNTargets = []Target{
	{"CDN", "Akamai Edge", "www.akamai.com"},
	{"CDN", "AWS Static", "d1.awsstatic.com"},
	{"CDN", "CacheFly", "cachefly.cachefly.net"},
	{"CDN", "CDN77 Demo", "1906714720.rsc.cdn77.org"},
	{"CDN", "Cloudflare CDNJS", "cdnjs.cloudflare.com"},
	{"CDN", "Fastly Demo", "http-me.fastly.dev"},
	{"CDN", "Google Fonts Static", "fonts.gstatic.com"},
	{"CDN", "Google Hosted Libraries", "ajax.googleapis.com"},
	{"CDN", "jsDelivr", "cdn.jsdelivr.net"},
	{"CDN", "Microsoft Ajax CDN", "ajax.aspnetcdn.com"},
	{"CDN", "QUANTIL Edge", "www.quantil.com"},
	{"CDN", "Tencent EdgeOne", "edgeone.ai"},
	{"CDN", "UNPKG", "unpkg.com"},
	{"CDN", "Vercel Edge", "vercel.com"},
}

// Result is one endpoint's probe outcome.
type Result struct {
	Index    int
	Status   probe.Status
	Category string
	Name     string
	Domain   string
	IP       string
	Sent     int
	Rcvd     int
	LossPct  float64
	AvgRTT   float64
}

// Prober is the subset of probe.Prober needed here.
type Prober interface {
	ProbeTarget(ctx context.Context, prov, isp, host, ip string, port int) probe.Result
}

// AllTargets returns the site targets followed by the CDN targets.
func AllTargets() []Target {
	all := make([]Target, 0, len(SiteTargets)+len(CDNTargets))
	all = append(all, SiteTargets...)
	all = append(all, CDNTargets...)
	return all
}

// TaskCount is the total number of international probe tasks.
func TaskCount() int { return len(SiteTargets) + len(CDNTargets) }

// RunAll probes every target with the given parallelism, invoking onDone after
// each result completes (for progress reporting). Results are returned in target
// order.
func RunAll(ctx context.Context, p Prober, parallel int, onDone func()) []Result {
	targets := AllTargets()
	results := make([]Result, len(targets))
	if parallel < 1 {
		parallel = 1
	}
	sem := make(chan struct{}, parallel)
	var wg sync.WaitGroup
	var completed int64
	for i, tgt := range targets {
		wg.Add(1)
		sem <- struct{}{}
		go func(idx int, tg Target) {
			defer wg.Done()
			defer func() { <-sem }()
			results[idx] = probeOne(ctx, p, idx+1, tg)
			atomic.AddInt64(&completed, 1)
			if onDone != nil {
				onDone()
			}
		}(i, tgt)
	}
	wg.Wait()
	return results
}

func probeOne(ctx context.Context, p Prober, index int, tg Target) Result {
	r := Result{Index: index, Category: tg.Category, Name: tg.Name, Domain: tg.Domain, Status: probe.StatusFail, LossPct: 100, AvgRTT: -1}
	ip, ok := iputil.ResolveFirstPublicIPv4(ctx, tg.Domain)
	if !ok {
		return r
	}
	r.IP = ip
	pr := p.ProbeTarget(ctx, tg.Name, tg.Category, tg.Domain, ip, 443)
	if pr.Status == probe.StatusOK && pr.Rcvd > 0 {
		r.Status = probe.StatusOK
		r.Sent, r.Rcvd, r.LossPct, r.AvgRTT = pr.Sent, pr.Rcvd, pr.LossPct, pr.AvgRTT
	} else {
		r.Sent, r.Rcvd, r.LossPct = pr.Sent, pr.Rcvd, pr.LossPct
		if pr.LossPct == 0 {
			r.LossPct = 100
		}
	}
	return r
}
