// Package fail is a refusal on its way out: exit code, log step and what the user is told.
package fail

import (
	"fmt"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
)

// Failure prints as the script's die ("error: <Msg>", then the exit code line), or as Lines verbatim.
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

// Printed is a refusal printed line by line with no "exit code" line; Msg goes to the log.
func Printed(code exitcode.Code, step, logMsg string, lines ...string) *Failure {
	return &Failure{Code: code, Step: step, Msg: logMsg, Lines: lines}
}
