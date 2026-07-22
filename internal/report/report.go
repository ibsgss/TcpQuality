// Package report builds the CSV result file and uploads it to the report API.
package report

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// csvHeader is the localized column header row.
const csvHeader = "网络,IP版本,省份,运营商,域名,IP,状态,发送,收到,丢包率(%),平均延迟ms,线路"

// Builder accumulates CSV rows with a UTF-8 BOM prefix.
type Builder struct {
	buf bytes.Buffer
}

// NewBuilder returns a Builder seeded with the BOM and header row.
func NewBuilder() *Builder {
	b := &Builder{}
	b.buf.Write([]byte{0xEF, 0xBB, 0xBF}) // UTF-8 BOM
	b.buf.WriteString(csvHeader)
	b.buf.WriteByte('\n')
	return b
}

// AddRow appends one already-formatted CSV record (fields joined externally).
func (b *Builder) AddRow(fields ...string) {
	b.buf.WriteString(strings.Join(fields, ","))
	b.buf.WriteByte('\n')
}

// AddProbe appends a probe result row.
func (b *Builder) AddProbe(network, ipver, prov, isp, host, ip, status string, sent, rcv int, loss, lat float64, route string) {
	b.AddRow(network, ipver, prov, isp, host, ip, status,
		fmt.Sprintf("%d", sent), fmt.Sprintf("%d", rcv),
		fmt.Sprintf("%.2f", loss), fmt.Sprintf("%.3f", lat), route)
}

// Bytes returns the CSV content.
func (b *Builder) Bytes() []byte { return b.buf.Bytes() }

// WriteFile writes the CSV to path.
func (b *Builder) WriteFile(path string) error {
	return os.WriteFile(path, b.buf.Bytes(), 0o644)
}

// DefaultPath returns a timestamped CSV path in the system temp dir.
func DefaultPath() string {
	return fmt.Sprintf("%s/zstatic_nping_%s.csv", os.TempDir(), time.Now().Format("20060102_150405"))
}

// UploadResult is the parsed response from the report API.
type UploadResult struct {
	URL       string `json:"url"`
	TodayUses int    `json:"todayUses"`
	TotalUses int    `json:"totalUses"`
}

// Upload posts the CSV to apiURL and returns the parsed response.
func Upload(ctx context.Context, apiURL string, csv []byte, reportTime string) (*UploadResult, error) {
	client := &http.Client{Timeout: 30 * time.Second}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, apiURL, bytes.NewReader(csv))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "text/csv; charset=utf-8")
	req.Header.Set("X-Report-Time", reportTime)
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("上传失败 HTTP %d", resp.StatusCode)
	}
	var out UploadResult
	if err := json.Unmarshal(body, &out); err != nil {
		return nil, fmt.Errorf("解析响应失败: %w", err)
	}
	if out.URL == "" {
		return nil, fmt.Errorf("响应缺少报告链接")
	}
	return &out, nil
}
