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
	"os/exec"
)

// Exec runs script with args as $1..$n and returns stdout and stderr
// together (the script's 2>&1), and a non-nil error on a non-zero exit.
type Exec interface {
	Run(script string, args ...string) (string, error)
}

// Local runs on this machine, as the hub host does.
type Local struct{}

func (Local) Run(script string, args ...string) (string, error) {
	out, err := exec.Command("/bin/bash", append([]string{"-c", script, "sts"}, args...)...).CombinedOutput()
	return string(out), err
}
