// Package manifest fingerprints a save directory the way the bash script's
// MANIFEST_SCRIPT does, byte for byte: one line per regular file,
// "<sha256>  <size>  ./<path>", sorted bytewise, excluded names left out.
// Decisions are made on these fingerprints, never on sizes or mtimes: two
// saves can have the same size and different contents (CLAUDE.md).
package manifest

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

// Always excluded, as the script passes them before SYNC_EXCLUDE.
const (
	SnapDirName = "star-traders-sync-snapshots"
	LockDirName = ".sts-lock"
)

// Manifest is a directory's file list.
type Manifest struct {
	Lines []string // "<sha256>  <size>  ./<path>", sorted
	// Unhashable files, as "./<path>": their contents cannot be compared,
	// so a sync refuses (13) rather than guess.
	Unhashable []string
}

// Text is the manifest as the script prints it, without the final newline
// (its callers capture it with $(...), which drops that).
func (m Manifest) Text() string {
	var all []string
	all = append(all, m.Lines...)
	for _, u := range m.Unhashable {
		all = append(all, "STS_UNHASHABLE  "+u)
	}
	sort.SliceStable(all, func(i, j int) bool { return pathOf(all[i]) < pathOf(all[j]) })
	return strings.Join(all, "\n")
}

// pathOf: the script sorts find's output - the paths - before hashing, so
// order is by path whatever the line holds.
func pathOf(line string) string {
	if i := strings.Index(line, "  ./"); i >= 0 {
		return line[i+2:]
	}
	return line
}

// Count is how many files it lists.
func (m Manifest) Count() int { return len(m.Lines) + len(m.Unhashable) }

// ErrUnhashable: the manifest lists something whose contents could not be
// read. Its fingerprint would compare equal to another side's with the
// same unreadable path whatever the contents, so there is none: a sync
// refuses (13) rather than decide on it (the script's
// assert_manifest_hashable).
var ErrUnhashable = errors.New("some files cannot be fingerprinted")

// Fingerprint is the sha256 of Text, or "empty" for no files, as
// fingerprint_of_manifest computes it - and an error if anything in it is
// unhashable, so such a manifest can never reach a decision.
func (m Manifest) Fingerprint() (string, error) {
	if len(m.Unhashable) > 0 {
		return "", fmt.Errorf("%w: %s", ErrUnhashable, strings.Join(m.Unhashable, ", "))
	}
	t := m.Text()
	if t == "" {
		return "empty", nil
	}
	sum := sha256.Sum256([]byte(t))
	return hex.EncodeToString(sum[:]), nil
}

// matcher is one exclude name, with find(1)'s fnmatch semantics and no
// FNM_PATHNAME: "*" matches anything, "/" included. The names are limited
// to [A-Za-z0-9._*@+-] by config validation, so "*" is the only special.
type matcher struct{ name, path *regexp.Regexp }

func newMatcher(n string) matcher {
	glob := strings.ReplaceAll(regexp.QuoteMeta(n), `\*`, ".*")
	// (?s): fnmatch's * matches a newline too; Go's . does not without it.
	return matcher{
		name: regexp.MustCompile("(?s)^" + glob + "$"),       // ! -name N
		path: regexp.MustCompile(`(?s)^\./` + glob + `/.*$`), // ! -path ./N/*
	}
}

// Build lists dir. A missing dir is an empty manifest (the script's
// "cd || exit 0").
//
// Unlike the script, nothing unreadable is skipped silently. find's errors
// go to /dev/null there, so an unreadable subdirectory just shrinks the
// manifest and the script refuses only later, at the snapshot or the
// transfer. Here an unreadable subdirectory is listed as unhashable
// ("./sub/"), which refuses (13) before anything is decided, and an
// unreadable dir itself is an error: never an "empty" manifest that would
// read as FIRST_SEED or LOCAL_EMPTIED.
func Build(dir string, exclude []string) (Manifest, error) {
	names := append([]string{SnapDirName, LockDirName}, exclude...)
	var ms []matcher
	for _, n := range names {
		ms = append(ms, newMatcher(n))
	}
	var m Manifest
	var files []string
	st, err := os.Stat(dir)
	switch {
	case errors.Is(err, fs.ErrNotExist):
		return m, nil // nothing there yet: empty, as the script's cd || exit 0
	case err != nil:
		return m, fmt.Errorf("cannot read %s: %w", dir, err) // EACCES, EIO, a stale mount
	case !st.IsDir():
		return m, fmt.Errorf("%s is not a directory", dir)
	}
	// WalkDir does not follow a symlinked root - it would report the link
	// itself and no files, an "empty" side. The script's cd follows it.
	real, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return m, fmt.Errorf("cannot resolve %s: %w", dir, err)
	}
	dir = real
	var unreadable []string
	walkErr := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if p == dir {
				return err
			}
			rel, _ := filepath.Rel(dir, p)
			under := "./" + filepath.ToSlash(rel) + "/"
			// Nothing under an excluded directory is listed anyway, so
			// one we cannot read is no reason to refuse.
			excluded := false
			for _, x := range ms {
				if x.path.MatchString(under) {
					excluded = true
				}
			}
			if !excluded {
				unreadable = append(unreadable, under)
			}
			if d != nil && d.IsDir() {
				return fs.SkipDir
			}
			return nil
		}
		if !d.Type().IsRegular() {
			return nil
		}
		rel, _ := filepath.Rel(dir, p)
		dot := "./" + filepath.ToSlash(rel)
		for _, x := range ms {
			if x.name.MatchString(d.Name()) || x.path.MatchString(dot) {
				return nil
			}
		}
		files = append(files, dot)
		return nil
	})
	if walkErr != nil {
		return m, fmt.Errorf("cannot read %s: %w", dir, walkErr)
	}
	m.Unhashable = append(m.Unhashable, unreadable...)
	sort.Strings(files)
	for _, f := range files {
		h, size, err := hashFile(filepath.Join(dir, filepath.FromSlash(f[2:])))
		if err != nil {
			m.Unhashable = append(m.Unhashable, f)
			continue
		}
		m.Lines = append(m.Lines, fmt.Sprintf("%s  %d  %s", h, size, f))
	}
	return m, nil
}

func hashFile(p string) (string, int64, error) {
	f, err := os.Open(p)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	h := sha256.New()
	n, err := io.Copy(h, f)
	if err != nil {
		return "", 0, err
	}
	return hex.EncodeToString(h.Sum(nil)), n, nil
}
