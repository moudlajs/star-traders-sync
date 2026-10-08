// Package logx writes the bash script's log: "<UTC time> <LEVEL> <step> <message>", same file and rotation.
package logx

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"
)

// Logger appends to File; write errors are ignored, since a log that cannot be written never stops a sync.
type Logger struct {
	File     string
	Level    string // DEBUG, INFO, WARN or ERROR
	MaxBytes int64
	Keep     int
	Verbose  io.Writer // --verbose mirrors lines here (stderr); nil for none
	Now      func() time.Time
}

func levelNum(l string) int {
	switch l {
	case "DEBUG":
		return 10
	case "WARN":
		return 30
	case "ERROR":
		return 40
	}
	return 20
}

// Log writes one line if level is at or above the threshold.
func (l *Logger) Log(level, step, format string, a ...any) {
	if levelNum(level) < levelNum(l.Level) {
		return
	}
	now := time.Now
	if l.Now != nil {
		now = l.Now
	}
	line := fmt.Sprintf("%s %-5s %-14s %s\n", now().UTC().Format("2006-01-02T15:04:05Z"), level, step, fmt.Sprintf(format, a...))
	_ = os.MkdirAll(filepath.Dir(l.File), 0o755)
	l.rotate()
	if f, err := os.OpenFile(l.File, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644); err == nil {
		_, _ = f.WriteString(line)
		_ = f.Close()
	}
	if l.Verbose != nil {
		_, _ = io.WriteString(l.Verbose, line)
	}
}

func (l *Logger) rotate() {
	st, err := os.Stat(l.File)
	if err != nil || l.MaxBytes <= 0 || st.Size() < l.MaxBytes {
		return
	}
	_ = os.Remove(fmt.Sprintf("%s.%d", l.File, l.Keep))
	for i := l.Keep; i > 1; i-- {
		prev := fmt.Sprintf("%s.%d", l.File, i-1)
		if _, err := os.Stat(prev); err == nil {
			_ = os.Rename(prev, fmt.Sprintf("%s.%d", l.File, i))
		}
	}
	_ = os.Rename(l.File, l.File+".1")
}
