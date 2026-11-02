# Nightly build (CompanionViewer-Nightly)

`update-nightly.sh` keeps the `merge-test` branch (our commits on upstream Firestorm `master`) up to
date and installs it as **CompanionViewer-Nightly**. Linux only; it uses the chroot in the
merge-test worktree. Branch model and the manual procedure: `AGENTS.md`, "Updating from upstream".

Each run:
1. Fetches upstream `master`. If neither it nor `dev` changed since the last good build, it stops.
2. On a throwaway branch `nightly-candidate` in `../CompanionViewer-merge`: cherry-picks the `dev`
   commits after `refs/nightly/dev-synced`, then rebases onto upstream `master`. Conflicts in
   non-English files (we deleted those) are resolved by deleting them again, and non-English files
   upstream added are deleted in one extra commit. Any other conflict stops the run.
3. Builds with `--chan=Nightly --jobs 8` at the lowest CPU and I/O priority.
4. Only then moves `merge-test` to the candidate and installs to `~/.local/opt/companionviewer-nightly`,
   unless a Nightly viewer is running (then: `update-nightly.sh --install` later).

A run that needs a person changes nothing: `merge-test` stays where it was, and the job shows a
desktop notification ("Nightly needs you") and writes `~/.local/state/companionviewer-nightly/status`
and `last-run.log` (`build.log` for the build). Conflicts are then resolved in an interactive session
(redo step 2 by hand in the worktree, build, then `git update-ref refs/nightly/dev-synced dev`).
Nothing is pushed.

## Install
```sh
install -m 755 scripts/nightly/update-nightly.sh ~/.local/bin/companionviewer-update-nightly
install -m 644 scripts/nightly/companionviewer-nightly.{service,timer} ~/.config/systemd/user/
git update-ref refs/nightly/dev-synced dev   # once: the dev commits already in merge-test
systemctl --user daemon-reload
systemctl --user enable --now companionviewer-nightly.timer
```
Re-run the first line after changing the script (the service runs the installed copy, so a rebase
of the worktree can't change the script while it runs). Run now: `systemctl --user start
companionviewer-nightly.service`; follow it with `journalctl --user -fu companionviewer-nightly`.

User services only run while you are logged in, unless lingering is on (`loginctl enable-linger`).
The timer is `Persistent`, so a night missed while the machine was off runs at the next login.

`dev-synced` must be an ancestor of `dev`. When `dev` is rebased onto a new release tag the job stops
("dev was rewritten"); after carrying over by hand, point the ref at the new `dev`.

Settings (environment, e.g. via `systemctl --user edit companionviewer-nightly`): `CV_MAIN`,
`CV_NIGHTLY_WORKTREE`, `CV_NIGHTLY_INSTALL`, `CV_NIGHTLY_JOBS` (default 8).
