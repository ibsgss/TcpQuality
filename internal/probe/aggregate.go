package probe

// ShouldProbeBackup reports whether the backup endpoint should be tried given
// the primary result, mirroring the guard in test_one (primary failed or its
// loss exceeds 15%).
func ShouldProbeBackup(primary Result) bool {
	return primary.Status != StatusOK || primary.LossPct > 15
}

// Combine merges a primary and backup OK result, mirroring combine_probe_results.
// If either side is not OK it returns the backup unchanged.
func Combine(primary, backup Result) Result {
	if primary.Status != StatusOK || backup.Status != StatusOK {
		return backup
	}
	lat := 0.0
	switch {
	case primary.AvgRTT > 0 && backup.AvgRTT > 0:
		lat = (primary.AvgRTT + backup.AvgRTT) / 2
	case primary.AvgRTT > 0:
		lat = primary.AvgRTT
	default:
		lat = backup.AvgRTT
	}
	return Result{
		Status:   StatusOK,
		Province: primary.Province,
		ISP:      primary.ISP,
		Host:     primary.Host,
		IP:       primary.IP,
		Sent:     primary.Sent + backup.Sent,
		Rcvd:     primary.Rcvd + backup.Rcvd,
		LossPct:  (primary.LossPct + backup.LossPct) / 2,
		AvgRTT:   lat,
	}
}

// DecideWithBackup reproduces the post-backup decision tree of test_one.
func DecideWithBackup(primary, backup Result) Result {
	if primary.Status != StatusOK || primary.LossPct >= 100 {
		return backup
	}
	if backup.Status == StatusOK {
		if backup.LossPct > 0 {
			return Combine(primary, backup)
		}
		return backup
	}
	return primary
}
