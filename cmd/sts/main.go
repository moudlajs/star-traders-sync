// Command sts is the Go build of star-traders-sync (v2.0, #19). Until the
// cutover (#26) the bash script in bin/ is the shipped tool and this one
// is checked against it by tests/parity.sh.
package main

import (
	"os"

	"github.com/moudlajs/star-traders-sync/internal/cli"
)

func main() {
	os.Exit(cli.Main(os.Args[1:], cli.System()))
}
