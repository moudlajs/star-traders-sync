// Package hubexec runs a shell snippet where the hub lives: on this
// machine when it is the hub host, over ssh otherwise - the script's
// hub_exec_args. Values always travel as positional parameters, never
// spliced into the script text.
//
// For macOS parity (v2.0) the hub runs the same snippets the bash script
// sends. A hub without bash (Windows, v2.1) gets another implementation
// behind the same interface.
package hubexec

import (
	"bytes"
	"io"
	"os/exec"
	"strings"
)

// Exec runs script with args as $1..$n.
type Exec interface {
	// Run returns stdout and stderr together (the script's 2>&1), and a
	// non-nil error on a non-zero exit.
	Run(script string, args ...string) (string, error)
	// Output returns stdout only; stderr goes to errw, as the script's
	// calls without 2>&1 let it through to the terminal.
	Output(errw io.Writer, script string, args ...string) (string, error)
}

// Local runs on this machine, as the hub host does.
type Local struct{}

func (Local) cmd(script string, args []string) *exec.Cmd {
	return exec.Command("/bin/bash", append([]string{"-c", script, "sts"}, args...)...)
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

// SSH runs on the hub over ssh: "bash -s -- 'arg'..." with the script on
// stdin, so its text never passes through the remote shell's parser.
type SSH struct {
	Opts   []string // the script's SSH_OPTS, word-split
	Target string   // user@endpoint
}

// Options is ssh_opts: BatchMode, timeout and StrictHostKeyChecking are
// fixed on purpose - an unknown or changed host key must fail loudly, never
// be accepted. SSH_EXTRA_OPTS is split on whitespace, never globbed.
func Options(connectTimeout, port, extra string) []string {
	o := []string{"-o", "BatchMode=yes", "-o", "ConnectTimeout=" + connectTimeout,
		"-o", "StrictHostKeyChecking=yes", "-p", port}
	return append(o, strings.Fields(extra)...)
}

// OptionsText is the script's $SSH_OPTS as one string, for the commands it
// prints: "ssh $(ssh_opts) ..." keeps the space before an empty
// SSH_EXTRA_OPTS, and the printed text has to be the script's, byte for
// byte (tests/parity.sh).
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
