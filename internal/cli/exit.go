package cli

import (
	"os"
	"os/signal"
	"sync"
	"syscall"

	"github.com/moudlajs/star-traders-sync/internal/transfer"
)

// exiter is the script's EXIT trap for the Go build: what has to be undone
// on the way out (locks, staging), run on an interrupt with the script's
// exit code - INT 130, TERM 143, HUP 129, PIPE 141 - and, if a swap is in
// flight, only once it has finished. Installed before the first lock, so no
// signal can leave one behind.
type exiter struct {
	mu    sync.Mutex
	hooks []func()
	guard *transfer.Guard
}

func (e *exiter) add(h func()) {
	e.mu.Lock()
	e.hooks = append(e.hooks, h)
	e.mu.Unlock()
}

func (e *exiter) setGuard(g *transfer.Guard) {
	e.mu.Lock()
	e.guard = g
	e.mu.Unlock()
}

// run runs every hook, newest first; each is safe to run twice, since the
// normal path releases the same things.
func (e *exiter) run() {
	e.mu.Lock()
	hooks := append([]func(){}, e.hooks...)
	e.mu.Unlock()
	for i := len(hooks) - 1; i >= 0; i-- {
		hooks[i]()
	}
}

var signalCodes = map[os.Signal]int{syscall.SIGINT: 130, syscall.SIGTERM: 143, syscall.SIGHUP: 129, syscall.SIGPIPE: 141}

// watch starts handling the signals; the returned func stops it.
func (e *exiter) watch() func() {
	ch := make(chan os.Signal, 1)
	signal.Notify(ch, syscall.SIGINT, syscall.SIGTERM, syscall.SIGHUP, syscall.SIGPIPE)
	done := make(chan struct{})
	go func() {
		select {
		case sig := <-ch:
			code := signalCodes[sig]
			out := func() { e.run(); os.Exit(code) }
			e.mu.Lock()
			g := e.guard
			e.mu.Unlock()
			if g != nil {
				g.Interrupt(out)
			} else {
				out()
			}
		case <-done:
		}
	}()
	return func() { signal.Stop(ch); close(done) }
}
