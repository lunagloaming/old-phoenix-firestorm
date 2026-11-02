#!/bin/bash
# Companion Viewer nightly: carry new `dev` commits over to `merge-test`, rebase `merge-test` onto
# upstream Firestorm `master`, build it as CompanionViewer-Nightly and install it.
#
# Everything happens on a throwaway branch (`nightly-candidate`) in the merge-test worktree.
# `merge-test` itself only moves after a clean rebase and a successful build, so a night that needs
# a human (a merge conflict, a failed build) changes nothing: the job stops, says why (desktop
# notification + status file) and the next interactive session resolves it.
#
# Usage: update-nightly.sh [--force]   (--force: rebuild even if nothing changed upstream)
#        update-nightly.sh --install   (only install the last good build, if no Nightly viewer runs)
#
# Run by companionviewer-nightly.service (see scripts/nightly/README.md). Not Python, on purpose.
set -euo pipefail

MAIN="${CV_MAIN:-$HOME/Projects/CompanionViewer}"            # main clone (branch dev)
WT="${CV_NIGHTLY_WORKTREE:-$HOME/Projects/CompanionViewer-merge}"  # merge-test worktree
BRANCH=merge-test
CANDIDATE=nightly-candidate
SYNC_REF=refs/nightly/dev-synced     # last dev commit already carried over to merge-test
INSTALL="${CV_NIGHTLY_INSTALL:-$HOME/.local/opt/companionviewer-nightly}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/companionviewer-nightly"
JOBS="${CV_NIGHTLY_JOBS:-8}"         # fewer than the interactive 14: less heat at night
BUILD_ARGS="--ninja --jobs $JOBS --chan=Nightly --no-package -DLL_TESTS:BOOL=FALSE"

mkdir -p "$STATE"
LOG="$STATE/last-run.log"
STATUS="$STATE/status"

FORCE=0 INSTALL_ONLY=0
case "${1:-}" in
    --force) FORCE=1 ;;
    --install) INSTALL_ONLY=1 ;;
    "") ;;
    *) echo "usage: $0 [--force|--install]" >&2; exit 64 ;;
esac

exec 9> "$STATE/lock"
flock -n 9 || { echo "Another nightly run is in progress." >&2; exit 0; }
exec > >(tee "$LOG") 2>&1
echo "== Companion Viewer nightly, $(date -Is)"

notify() { # urgency summary body
    notify-send -a "Companion Viewer Nightly" -u "$1" "$2" "$3" 2>/dev/null || true
}
finish() { # code summary body
    local code="$1"; shift
    printf '%s\n%s\n%s\n' "$(date -Is)" "$1" "$2" > "$STATUS"
    echo "== $1: $2"
    if [ "$code" -ne 0 ]; then notify critical "$1" "$2  (log: $LOG)"; else notify normal "$1" "$2"; fi
    exit "$code"
}
g() { git -C "$WT" "$@"; }

nightly_running() { # is a viewer from $INSTALL running?
    local p
    for p in $(pgrep -x do-not-directly 2>/dev/null || true); do
        [[ "$(readlink "/proc/$p/exe" 2>/dev/null)" == "$INSTALL/"* ]] && return 0
    done
    return 1
}

install_build() {
    local built packaged="$WT/build-linux-x86_64/newview/packaged"
    built="$(cat "$STATE/built" 2>/dev/null || true)"
    if [ -z "$built" ] || [ "$built" = "$(cat "$STATE/installed" 2>/dev/null || true)" ]; then
        echo "Nothing new to install."; return 0
    fi
    if nightly_running; then
        echo "A Nightly viewer is running; not installing. Run with --install after closing it."
        return 1
    fi
    # (set -e does not apply inside a function called from an if, so check explicitly)
    rsync -rptgoDLK --delete --exclude='bin/.debug' "$packaged/" "$INSTALL/" || return 2
    chmod 755 "$INSTALL"/bin/{dullahan_host,chrome-sandbox,SLVoice} || return 2
    echo "$built" > "$STATE/installed"
    echo "Installed $(cat "$packaged/build_data.json" 2>/dev/null | grep -o '"Version": "[^"]*"') to $INSTALL"
}

if [ "$INSTALL_ONLY" = 1 ]; then
    if install_build; then finish 0 "Nightly installed" "$(cat "$STATE/built" 2>/dev/null)"; fi
    finish 1 "Nightly not installed" "A Nightly viewer is still running."
fi

# --- Preconditions -------------------------------------------------------------------------------
[ -d "$WT" ] || finish 1 "Nightly: setup problem" "No worktree at $WT."
[ -z "$(g status --porcelain --untracked-files=no)" ] \
    || finish 1 "Nightly needs you" "The merge-test worktree has uncommitted changes; left alone."
gitdir="$(g rev-parse --absolute-git-dir)"
if [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] || [ -f "$gitdir/CHERRY_PICK_HEAD" ]; then
    finish 1 "Nightly needs you" "A rebase or cherry-pick is still in progress in the merge-test worktree."
fi
current="$(g symbolic-ref --short -q HEAD || true)"
if [ "$current" != "$BRANCH" ]; then
    [ "$current" = "$CANDIDATE" ] || finish 1 "Nightly needs you" "The worktree is on '$current', not $BRANCH."
    g switch -q "$BRANCH"     # a failed candidate from an earlier night
fi
g rev-parse -q --verify "$SYNC_REF" > /dev/null \
    || finish 1 "Nightly: setup problem" "$SYNC_REF is not set (the last dev commit already in $BRANCH)."
g merge-base --is-ancestor "$SYNC_REF" dev \
    || finish 1 "Nightly needs you" "dev was rewritten (no longer contains $SYNC_REF); carry it over by hand."

# --- Anything to do? -----------------------------------------------------------------------------
g fetch -q upstream master || finish 1 "Nightly: fetch failed" "Could not fetch upstream master."
up="$(g rev-parse upstream/master)"
new_dev="$(g rev-list --reverse "$SYNC_REF..dev")"
if [ "$FORCE" = 0 ] && [ -z "$new_dev" ] && g merge-base --is-ancestor "$up" "$BRANCH" \
   && [ "$(cat "$STATE/built" 2>/dev/null || true)" = "$(g rev-parse "$BRANCH")" ]; then
    install_build || true
    finish 0 "Nightly up to date" "upstream master ${up:0:10}; nothing new from dev."
fi

# --- Candidate: dev commits, then the rebase -----------------------------------------------------
g switch -q -C "$CANDIDATE" "$BRANCH"
back_out() { g cherry-pick --abort 2>/dev/null || true; g rebase --abort 2>/dev/null || true; g switch -q "$BRANCH"; }

for c in $new_dev; do
    echo "Carrying over dev $(g log -1 --format='%h %s' "$c")"
    if ! g cherry-pick -x "$c"; then
        back_out
        finish 1 "Nightly needs you" "dev commit $(g log -1 --format='%h' "$c") conflicts with $BRANCH."
    fi
done

# Non-English XUI/HTML/installer files: we deleted them (English only), so upstream changes to them
# conflict as modify/delete; upstream also adds new ones. Both are resolved by deleting them again.
non_english() {
    grep -E '/(xui|html)/[^/]+/|installers/windows/lang_' \
        | grep -vE '/xui/en/|/html/(en-us|en|common)/|lang_en-us\.nsi$' || true
}

if ! g -c merge.conflictStyle=diff3 rebase "$up"; then
    while :; do
        conflicted="$(g diff --name-only --diff-filter=U)"
        others="$(printf '%s\n' "$conflicted" | grep -v '^$' | grep -vxFf <(printf '%s\n' "$conflicted" | non_english) || true)"
        if [ -z "$conflicted" ]; then
            back_out
            finish 1 "Nightly needs you" "The rebase onto upstream ${up:0:10} stopped without a conflict (an empty commit?)."
        fi
        if [ -n "$others" ]; then
            back_out
            finish 1 "Nightly needs you" "Rebase onto upstream ${up:0:10} conflicts in: $(echo $others | cut -c1-300)"
        fi
        printf '%s\n' "$conflicted" | non_english | xargs -r git -C "$WT" rm -q -f --
        echo "Deleted non-English files again: $(printf '%s\n' "$conflicted" | non_english | wc -l)"
        if GIT_EDITOR=true g -c merge.conflictStyle=diff3 rebase --continue; then break; fi
        [ -d "$gitdir/rebase-merge" ] || [ -d "$gitdir/rebase-apply" ] || break
    done
fi

added="$(g ls-files | non_english)"
if [ -n "$added" ]; then
    printf '%s\n' "$added" | xargs -r git -C "$WT" rm -q -f --
    g commit -q -m "Nightly: delete non-English files upstream added

English only (see AGENTS.md); $(printf '%s\n' "$added" | wc -l) files.

Committed by scripts/nightly/update-nightly.sh"
    echo "Deleted $(printf '%s\n' "$added" | wc -l) non-English files upstream added."
fi

# --- Build ---------------------------------------------------------------------------------------
echo "Building $(g rev-parse --short HEAD) on upstream ${up:0:10} with --jobs $JOBS"
start=$(date +%s)
build() {
    local i
    for i in 1 2 3; do   # a fresh configure sometimes misses a just-downloaded library (AGENTS.md)
        if (cd "$WT" && nice -n 19 ionice -c 3 .chroot/enter bash -c \
                "autobuild configure -A 64 -c ReleaseFS_open -- $BUILD_ARGS"); then
            break
        fi
        [ "$i" = 3 ] && return 1
    done
    (cd "$WT" && nice -n 19 ionice -c 3 .chroot/enter bash -c \
        "autobuild build -A 64 -c ReleaseFS_open --no-configure -- $BUILD_ARGS")
}
if ! build > "$STATE/build.log" 2>&1; then
    tail -30 "$STATE/build.log"
    g switch -q "$BRANCH"
    finish 1 "Nightly needs you" "The build of the rebased branch failed (left as $CANDIDATE; see $STATE/build.log)."
fi
echo "Build took $(( ($(date +%s) - start) / 60 )) min."

# --- Accept: move merge-test, remember what was carried over and built ---------------------------
g branch -f "$BRANCH" "$CANDIDATE"
g switch -q "$BRANCH"
g branch -q -D "$CANDIDATE"
g update-ref "$SYNC_REF" dev
g rev-parse "$BRANCH" > "$STATE/built"

version="$(grep -o '"Version": "[^"]*"' "$WT/build-linux-x86_64/newview/packaged/build_data.json" | cut -d'"' -f4)"
if install_build; then
    finish 0 "Nightly $version installed" "On upstream master ${up:0:10}."
fi
finish 0 "Nightly $version built" "Not installed: a Nightly viewer is running. Close it and run update-nightly.sh --install."
