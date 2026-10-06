// Code generated from bin/star-traders-sync; DO NOT EDIT.
// TestSnippetsMatchTheScript fails when they drift: a remote hub runs the
// script's own text, so the two builds read it the same way.

package hub

const (
	manifestScript  = "dir=\"$1\"; shift\ncd \"$dir\" 2>/dev/null || exit 0\n# set -f covers both building and using $prune_args: it must word-split but\n# must NOT glob. SYNC_EXCLUDE legally contains * (see validate_config), and\n# without this an entry like *.bak expands against the directory we just\n# moved into, turning \"-name *.bak\" into \"-name a.bak b.bak\" - which find rejects,\n# leaving an empty manifest that nothing downstream detects.\nset -f\nprune_args=\"\"\nfor n in \"$@\"; do\n    prune_args=\"$prune_args ! -name $n ! -path ./$n/*\"\ndone\n# shellcheck disable=SC2086\nLC_ALL=C find . -type f $prune_args 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do\n    h=$(shasum -a 256 \"$f\" 2>/dev/null | cut -d\" \" -f1)\n    z=$(stat -f%z \"$f\" 2>/dev/null)\n    if [ -z \"$h\" ] || [ -z \"$z\" ]; then\n        printf \"STS_UNHASHABLE  %s\\n\" \"$f\"\n    else\n        printf \"%s  %s  %s\\n\" \"$h\" \"$z\" \"$f\"\n    fi\ndone\nset +f"
	newestScript    = "\n        cd \"$1\" 2>/dev/null || exit 0\n        LC_ALL=C find . -type f ! -path \"./$2/*\" ! -path \"./$3/*\" \\\n            -exec stat -f%m {} + 2>/dev/null | LC_ALL=C sort -n | tail -1\n"
	checkPathScript = "\n        d=\"$1\"\n        if [ ! -e \"$d\" ]; then\n            for cand in \"$d\".sts-old-*; do\n                [ -d \"$cand\" ] || continue\n                echo STS_ORPHAN\n                echo \"$cand\"\n                exit 0\n            done\n            echo STS_NOENT\n            exit 0\n        fi\n        [ -d \"$d\" ] || { echo STS_NOTDIR; exit 0; }\n        [ -r \"$d\" ] || { echo STS_NOREAD; exit 0; }\n        [ -w \"$d\" ] || { echo STS_NOWRITE; exit 0; }\n        echo STS_OK\n"
	lockInfoScript  = "cat \"$1/owner\" 2>/dev/null | head -3 | tr \"\\n\" \" \""
)
