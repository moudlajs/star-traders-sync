// Package decide is the conflict state machine, ported from the script's decide(); nothing is merged or auto-picked.
package decide

// Decision is one of the script's decision names, as status --json and --expect-decision use them.
type Decision string

const (
	InSync           Decision = "INSYNC"
	HubOnly          Decision = "HUB_ONLY"
	LocalOnly        Decision = "LOCAL_ONLY"
	BothChanged      Decision = "BOTH_CHANGED"
	FirstRunConflict Decision = "FIRSTRUN_CONFLICT"
	FirstSeed        Decision = "FIRST_SEED"
	HubEmpty         Decision = "HUB_EMPTY"
	DivergedState    Decision = "DIVERGED_STATE"
	LocalEmptied     Decision = "LOCAL_EMPTIED"
)

// State is the last recorded sync; a missing or foreign state file is a first run, never "nothing changed".
type State struct {
	FirstRun  bool
	Direction string
	Epoch     string
	LocalFP   string
	HubFP     string
}

// Side is one directory: its manifest fingerprint and file count.
type Side struct {
	FP    string
	Count int
}

// Decide is the script's decide(): fingerprints and the state, nothing else.
func Decide(local, hub Side, st State) Decision {
	if local.FP == hub.FP {
		return InSync
	}
	if st.FirstRun {
		switch {
		case hub.Count == 0 && local.Count > 0:
			return HubEmpty
		case local.Count == 0 && hub.Count > 0:
			return FirstSeed
		}
		return FirstRunConflict
	}
	lchanged := local.FP != st.LocalFP
	hchanged := hub.FP != st.HubFP
	switch {
	case lchanged && hchanged:
		return BothChanged
	case lchanged:
		return LocalOnly
	case hchanged:
		return HubOnly
	}
	// Neither side changed since the last sync, yet they differ: the record is wrong.
	return DivergedState
}

// Effective is effective_decision: Decide behind the emptied-side guards; status and every guard use it (#81).
func Effective(local, hub Side, st State) Decision {
	switch {
	case hub.Count == 0 && local.Count > 0:
		return HubEmpty // pull refuses (62); push needs --force=local
	case local.Count == 0 && hub.Count > 0 && !st.FirstRun:
		return LocalEmptied // push refuses (61); pull needs --force=hub
	}
	return Decide(local, hub, st)
}
