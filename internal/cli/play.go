package cli

import (
	"fmt"
	"time"

	"github.com/moudlajs/star-traders-sync/internal/exitcode"
	"github.com/moudlajs/star-traders-sync/internal/fail"
	"github.com/moudlajs/star-traders-sync/internal/platform"
)

// play is cmd_play; the hub lock is never held while the game runs.
func (s *syncer) play() *fail.Failure {
	if f := s.checkGameNotRunning(); f != nil {
		return f
	}
	offline := s.hub.EndpointKind == "offline"
	if offline {
		for _, l := range []string{
			"======================================================================",
			"THE HUB IS OFFLINE AND --offline-ok WAS GIVEN.",
			"Nothing was pulled. You are about to play on this machine's local",
			"save, which may be older than the hub's. Nothing will be pushed",
			"afterwards either. Sync by hand once the hub is reachable.",
			"======================================================================",
		} {
			s.warn("%s", l)
		}
		s.log.Log("WARN", "play", "playing offline, no pull, no push")
	} else {
		s.say("pulling before launch...")
		s.inPlay = true
		f := s.pull()
		s.inPlay = false
		if f != nil {
			return f
		}
	}

	start := time.Now().Unix()
	appID := s.cfg.Get("STEAM_APPID")
	s.say("launching Star Traders: Frontiers (appid %s)...", appID)
	s.log.Log("INFO", "play", "%s", platform.LaunchHint(appID))
	if platform.LaunchGame(appID) != nil {
		return fail.New(exitcode.GameNoStart, "play", "'%s' failed - is Steam installed?", platform.LaunchHint(appID))
	}

	name := s.cfg.Get("GAME_PROCESS_NAME")
	timeout := s.cfg.Int("GAME_START_TIMEOUT")
	pid := ""
	for waited := 0; ; waited += 2 {
		if p := firstPid(name); p != "" {
			pid = p
			break
		}
		if waited >= timeout {
			break
		}
		time.Sleep(2 * time.Second)
	}
	if pid == "" {
		s.log.Log("ERROR", "play", "process '%s' never appeared within %ds", name, timeout)
		return fail.Printed(exitcode.GameNoStart, "play", "",
			"error: the game never started.",
			fmt.Sprintf("Waited %ds for a process named %s and saw nothing.", timeout, name),
			"Nothing was pushed - an unchanged save is not worth recording.",
			fmt.Sprintf("Check that STEAM_APPID=%s is right and Steam is installed:", appID),
			"  "+platform.LaunchHint(appID),
			"  "+platform.ProcessHint(name))
	}

	s.say("game running (pid %s) - waiting for it to exit. Ctrl-C here does not stop the game.", pid)
	s.log.Log("INFO", "play", "game started, pid %s", pid)
	// Steam sometimes re-execs the game: only three missed polls in a row (six seconds) is an exit.
	for gone, announced := 0, false; ; {
		if firstPid(name) != "" {
			gone = 0
		} else {
			gone++
			if !announced {
				s.say("game closed - making sure it stays closed...")
				announced = true
			}
			if gone >= 3 {
				break
			}
		}
		time.Sleep(2 * time.Second)
	}

	// Give a crash reporter time to write its report.
	time.Sleep(3 * time.Second)
	if crash := platform.CrashReport(s.env.Getenv("HOME"), name, start); crash != "" {
		s.log.Log("WARN", "play", "game exited via CRASH - report at %s", crash)
		s.warn("the game crashed (report: %s) - pushing the save anyway", crash)
	} else {
		s.log.Log("INFO", "play", "game exited cleanly (pid %s gone, no crash report)", pid)
		s.say("game exited.")
	}

	if offline {
		s.warn("hub still offline - NOT pushing. Run '%s push' when it is back.", prog)
		return nil
	}
	s.say("pushing after play...")
	return s.push()
}

func firstPid(name string) string {
	if ids := platform.ProcessIDs(name); len(ids) > 0 {
		return ids[0]
	}
	return ""
}
