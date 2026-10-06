// Package saves is this machine's save directory before anything reads it:
// it exists and is usable (check_local_save_path), and nothing an earlier,
// interrupted run left behind is mistaken for an empty save folder
// (recover_orphans).
package saves

import (
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/logx"
)

// CheckPath returns the directory to operate on: LOCAL_SAVE_PATH, or the
// target of a symlink there (said out loud), refusing (13) unless it
// exists, is a directory and can be read.
func CheckPath(p string, log *logx.Logger, stderr io.Writer) (string, *fail.Failure) {
	if fi, err := os.Lstat(p); err == nil && fi.Mode()&os.ModeSymlink != 0 {
		real, err := filepath.EvalSymlinks(p)
		if st, serr := os.Stat(p); err != nil || serr != nil || !st.IsDir() {
			return "", fail.New(exitcode.LocalSaveBad, "preflight", "LOCAL_SAVE_PATH is a symlink that does not resolve: %s", p)
		}
		log.Log("WARN", "preflight", "LOCAL_SAVE_PATH is a symlink, using its target %s", real)
		fmt.Fprintf(stderr, "warning: LOCAL_SAVE_PATH is a symlink; operating on its target %s\n", real)
		p = real
	}
	st, err := os.Stat(p)
	switch {
	case err != nil:
		return "", fail.New(exitcode.LocalSaveBad, "preflight", "LOCAL_SAVE_PATH does not exist: %s - launch the game once so it creates it, then re-run", p)
	case !st.IsDir():
		return "", fail.New(exitcode.LocalSaveBad, "preflight", "LOCAL_SAVE_PATH is not a directory: %s", p)
	}
	if f, err := os.Open(p); err != nil {
		return "", fail.New(exitcode.LocalSaveBad, "preflight", "LOCAL_SAVE_PATH is not readable: %s", p)
	} else {
		f.Close()
	}
	return p, nil
}

// RecoverOrphans looks for what an interrupted run left beside the save
// directory. A missing save directory with a parked .sts-old copy is an
// interrupted swap: the saves are intact there, and nothing runs until
// they are moved back, so an empty directory is never made on top of
// them. Staging directories are swept once they are clearly stale
// (sweep); status only reports them (sweep false).
func RecoverOrphans(savePath string, sweep bool, now time.Time, log *logx.Logger) *fail.Failure {
	if st, err := os.Stat(savePath); err != nil || !st.IsDir() {
		if parked, _ := filepath.Glob(savePath + ".sts-old-*"); len(parked) > 0 {
			for _, old := range parked {
				if st, err := os.Stat(old); err == nil && st.IsDir() {
					log.Log("ERROR", "recover", "interrupted swap detected: %s missing, saves parked at %s", savePath, old)
					return fail.Printed(exitcode.LocalSaveBad, "recover", "",
						"error: a previous run was interrupted while swapping directories.", "",
						"Your saves are INTACT at:", "  "+old, "",
						"Restore them with:", "  mv "+old+" "+savePath, "",
						"Nothing else will run until you do - this is deliberate, so an",
						"empty save directory cannot be created on top of the recovery.")
				}
			}
		}
	}

	// A staging directory younger than this may belong to a run that is
	// still going; the cost of waiting is nil, of deleting live data total.
	incoming, _ := filepath.Glob(filepath.Join(filepath.Dir(savePath), ".sts-incoming-*"))
	for _, d := range incoming {
		st, err := os.Stat(d)
		if err != nil || !st.IsDir() {
			continue
		}
		age := int64(now.Sub(st.ModTime()).Seconds())
		switch {
		case !sweep:
			log.Log("INFO", "recover", "staging directory present: %s (%ds old)", d, age)
		case age < 300:
			log.Log("WARN", "recover", "leaving recent staging directory %s (%ds old)", d, age)
		default:
			log.Log("WARN", "recover", "removing stale staging directory %s (%ds old)", d, age)
			_ = os.RemoveAll(d)
		}
	}
	parked, _ := filepath.Glob(savePath + ".sts-old-*")
	for _, old := range parked {
		if st, err := os.Stat(old); err == nil && st.IsDir() {
			log.Log("WARN", "recover", "previous generation left at %s - safe to delete once you are happy", old)
		}
	}
	return nil
}
