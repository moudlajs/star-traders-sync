// Command sts is the Go build of star-traders-sync.
package main

import (
	"os"

	"github.com/moudlajs/star-traders-sync/internal/cli"
)

func main() {
	os.Exit(cli.Main(os.Args[1:], cli.System()))
}
