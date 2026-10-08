// Package manifest fingerprints a save directory byte for byte as the script's MANIFEST_SCRIPT does.
// Decisions use fingerprints, never sizes or mtimes: two saves of the same size can differ.
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

const (
	SnapDirName = "star-traders-sync-snapshots"
	LockDirName = ".sts-lock"
)

// Manifest is a directory's file list.
type Manifest struct {
	Lines []string // "<sha256>  <size>  ./<path>", sorted
	// Unhashable files, as "./<path>": a sync refuses (13) rather than guess.
	Unhashable []string
}

// Text is the manifest as the script prints it, without the final newline $(...) drops.
func (m Manifest) Text() string {
	var all []string
	all = append(all, m.Lines...)
	for _, u := range m.Unhashable {
		all = append(all, "STS_UNHASHABLE  "+u)
	}
	sort.SliceStable(all, func(i, j int) bool { return pathOf(all[i]) < pathOf(all[j]) })
	return strings.Join(all, "\n")
}

// pathOf: the script sorts find's paths before hashing, so order is by path.
func pathOf(line string) string {
	if i := strings.Index(line, "  ./"); i >= 0 {
		return line[i+2:]
	}
	return line
}

// Count is how many files it lists.
func (m Manifest) Count() int { return len(m.Lines) + len(m.Unhashable) }

// ErrUnhashable: an unreadable file has no fingerprint, or two sides could compare equal whatever the contents.
var ErrUnhashable = errors.New("some files cannot be fingerprinted")

// Fingerprint is fingerprint_of_manifest: sha256 of Text, "empty" for no files, an error if anything is unhashable.
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

// matcher is one exclude name with find(1)'s fnmatch semantics, no FNM_PATHNAME: "*" matches "/" too.
type matcher struct{ name, path *regexp.Regexp }

func newMatcher(n string) matcher {
	glob := strings.ReplaceAll(regexp.QuoteMeta(n), `\*`, ".*")
	// (?s): fnmatch's * matches a newline too; Go's . does not without it.
	return matcher{
		name: regexp.MustCompile("(?s)^" + glob + "$"),       // ! -name N
		path: regexp.MustCompile(`(?s)^\./` + glob + `/.*$`), // ! -path ./N/*
	}
}

// Build lists dir; a missing dir is empty, but anything unreadable is unhashable or an error, never skipped.
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
		return m, nil
	case err != nil:
		return m, fmt.Errorf("cannot read %s: %w", dir, err)
	case !st.IsDir():
		return m, fmt.Errorf("%s is not a directory", dir)
	}
	// WalkDir does not follow a symlinked root; the script's cd does.
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
			// Nothing under an excluded directory is listed, so an unreadable one is no reason to refuse.
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
		// A newline in a name cannot survive the line-based manifest: unhashable, as in the script.
		if strings.ContainsAny(dot, "\n\r") {
			unreadable = append(unreadable, dot)
			return nil
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

// Parse reads a manifest in the script's text form, as MANIFEST_SCRIPT prints it on a remote hub.
func Parse(text string) Manifest {
	var m Manifest
	for _, line := range strings.Split(strings.TrimRight(text, "\n"), "\n") {
		switch {
		case line == "":
		case strings.HasPrefix(line, "STS_UNHASHABLE  "):
			m.Unhashable = append(m.Unhashable, strings.TrimPrefix(line, "STS_UNHASHABLE  "))
		default:
			m.Lines = append(m.Lines, line)
		}
	}
	return m
}
