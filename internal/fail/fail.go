// Package fail is a refusal on its way out: the exit code from the table,
// the log step, and what the user is told. Every non-zero exit carries one.
package fail

import (
	"fmt"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
)

// Failure: printed as "error: <Msg>" plus "exit code N - see <log>" (the
// script's die), or as Lines verbatim for the refusals the script prints
// in its own shape.
type Failure struct {
	Code  exitcode.Code
	Step  string
	Msg   string
	Lines []string
}

func (f *Failure) Error() string { return f.Msg }

// New is die CODE STEP MSG.
func New(code exitcode.Code, step, format string, a ...any) *Failure {
	return &Failure{Code: code, Step: step, Msg: fmt.Sprintf(format, a...)}
}

// Printed is a refusal the script prints line by line, with no
// "exit code" line: Msg is what goes to the log.
func Printed(code exitcode.Code, step, logMsg string, lines ...string) *Failure {
	return &Failure{Code: code, Step: step, Msg: logMsg, Lines: lines}
}
