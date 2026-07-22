package config

// ANSI color / style escape codes, mirroring the original bash script.
const (
	Red       = "\033[0;31m"
	Green     = "\033[0;32m"
	Yellow    = "\033[0;33m"
	Blue      = "\033[0;34m"
	Cyan      = "\033[0;36m"
	Magenta   = "\033[0;35m"
	White     = "\033[1;37m"
	Bold      = "\033[1m"
	Dim       = "\033[2m"
	Underline = "\033[4m"
	NC        = "\033[0m"
	BgRed     = "\033[41m"
	BgGreen   = "\033[42m"
	BgYellow  = "\033[43m"
)
