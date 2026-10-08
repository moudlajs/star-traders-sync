// Package hubexec runs a shell snippet where the hub lives, locally or over ssh (hub_exec_args).
// Values always travel as positional parameters, never spliced into the script text.
package hubexec

import (
	"bytes"
	"io"
	"os/exec"
	"strings"

	"github.com/moudlajs/star-traders-sync/internal/platform"
)

// Exec runs script with args as $1..$n.
type Exec interface {
	// Run returns stdout and stderr together (2>&1), and an error on a non-zero exit.
	Run(script string, args ...string) (string, error)
	// Output returns stdout only; stderr goes to errw.
	Output(errw io.Writer, script string, args ...string) (string, error)
}

// Local runs on this machine, as the hub host does.
type Local struct{}

func (Local) cmd(script string, args []string) *exec.Cmd {
	return exec.Command(platform.Shell, append([]string{"-c", script, "sts"}, args...)...)
}

func (l Local) Run(script string, args ...string) (string, error) {
	out, err := l.cmd(script, args).CombinedOutput()
	return string(out), err
}

func (l Local) Output(errw io.Writer, script string, args ...string) (string, error) {
	c := l.cmd(script, args)
	c.Stderr = errw
	out, err := c.Output()
	return string(out), err
}

// SSH runs on the hub as "bash -s" with the script on stdin, so the remote shell never parses its text.
type SSH struct {
	Opts   []string
	Target string
}

// Options is ssh_opts: BatchMode and StrictHostKeyChecking are fixed, so an unknown host key fails, never accepted.
func Options(connectTimeout, port, extra string) []string {
	o := []string{"-o", "BatchMode=yes", "-o", "ConnectTimeout=" + connectTimeout,
		"-o", "StrictHostKeyChecking=yes", "-p", port}
	return append(o, strings.Fields(extra)...)
}

// OptionsText is $SSH_OPTS as one string, byte for byte the script's, for printed commands.
func OptionsText(connectTimeout, port, extra string) string {
	return "-o BatchMode=yes -o ConnectTimeout=" + connectTimeout +
		" -o StrictHostKeyChecking=yes -p " + port + " " + extra
}

// Quote is the script's shq: one literal word for a POSIX shell.
func Quote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'"
}

func (s SSH) cmd(script string, args []string) *exec.Cmd {
	remote := "bash -s --"
	for _, a := range args {
		remote += " " + Quote(a)
	}
	c := exec.Command("ssh", append(append([]string{}, s.Opts...), s.Target, remote)...)
	c.Stdin = strings.NewReader(script + "\n") // the script's heredoc ends in a newline
	return c
}

func (s SSH) Run(script string, args ...string) (string, error) {
	out, err := s.cmd(script, args).CombinedOutput()
	return string(out), err
}

func (s SSH) Output(errw io.Writer, script string, args ...string) (string, error) {
	c := s.cmd(script, args)
	var o bytes.Buffer
	c.Stdout, c.Stderr = &o, errw
	err := c.Run()
	return o.String(), err
}
