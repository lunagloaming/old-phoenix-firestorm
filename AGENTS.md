# AGENTS.md — Companion Viewer

Notes for coding agents (and humans) resuming work on this repo from any machine.

## What this is
Companion Viewer is a fork of the Firestorm Second Life viewer (tag
`Firestorm_Release_7.2.5.81788`), rebranded as **"Companion Viewer"** (display name) /
**`CompanionViewer`** (files, channel, folders, binaries). It is not affiliated with or supported
by the Firestorm project. All work is on **`dev`** (base: `master`, the upstream Firestorm
mirror), including the rebrand and the multibox-memory port. The old `companion-rebrand` branch is
gone; its commits are the start of `dev`.

## Owner preferences
- **No Python for new code.** Helpers, plugins and tooling we add are written in **Rust** (or in the
  viewer's own C++). Upstream build tooling that happens to be Python (autobuild,
  `viewer_manifest.py`) is fine to use and patch.
- English only. Non-English XUI/HTML/installer strings have been removed; don't re-add them.
- Ask before committing; commit messages explain *why*.

## Rebrand rules
- Minimise Firestorm references, except where attribution belongs (About box credits, license
  headers, README attribution).
- **Hide, don't delete**, entry points to Firestorm community resources and firestormviewer.org
  services (help/wiki, blog, socials, Jira, release notes, download prompts). Don't add new
  firestormviewer.org links.
- Keep internal identifiers unchanged to ease upstream merges: `FS*` classes, settings keys,
  `firestorm_*` asset filenames, the `#Firestorm` inventory folder, the `firestorm` skin folder.
- Upstream build docs in `doc/` stay as they are.
- Mark our code changes with `// Companion Viewer:` comments.

## Building (macOS)
Tested on macOS 27 with Xcode 27.2, producing a universal (arm64 + x86_64) build.

1. **Build variables** live in a sibling clone, not in this repo (deliberately not vendored):
   ```sh
   git clone https://github.com/FirestormViewer/fs-build-variables.git ../fs-build-variables
   ```
   Xcode 27 rejects deployment targets below 12, so edit `../fs-build-variables/variables`:
   `LL_BUILD_DARWIN_DEPLOY_TARGET="12"` (was `"11"`). On the original machine this is local commit
   `f53b853` on that clone's `master`; it isn't pushed anywhere.
2. **Tool environment** (local-only, listed in `.git/info/exclude`):
   ```sh
   python3 -m venv .venv && .venv/bin/pip install autobuild cmake llsd
   cat > fs-env.sh <<'EOF'
   # Source this before building:  source fs-env.sh
   _fs_root="$(cd "$(dirname "${BASH_SOURCE[0]:-${(%):-%x}}")" && pwd)"
   source "$_fs_root/.venv/bin/activate"
   export AUTOBUILD_VARIABLES_FILE="$_fs_root/../fs-build-variables/variables"
   unset _fs_root
   EOF
   printf '.venv/\nfs-env.sh\n' >> .git/info/exclude
   ```
   (Known-good versions: autobuild 3.10.2, cmake 4.4.4, llsd 1.2.4.)
3. **Configure and build:**
   ```sh
   source fs-env.sh
   autobuild configure -A 64 -c ReleaseFS_open -- -DLL_TESTS:BOOL=FALSE
   autobuild build -A 64 -c ReleaseFS_open --no-configure
   ```
   Output: `build-darwin-universal/newview/Release/CompanionViewer.app` (not the x86_64 path the
   upstream docs mention). Running `xcodebuild` directly needs a prior `autobuild configure` in
   the same shell, because CMake regeneration reads `$ENV{LL_BUILD}`.
4. **Running:** `open build-darwin-universal/newview/Release/CompanionViewer.app`. Before relaunching
   after a rebuild, make sure the old process has really exited; an AppleScript quit can
   return "User canceled" and leave it running.

Logs: `~/Library/Application Support/CompanionViewer/logs/CompanionViewer.log`.

## Building (Linux)
Needs **GCC 14** (Ubuntu 24.04); `doc/building_linux.md` still says GCC 11, which fails. We build in a
rootless Ubuntu 24.04 chroot.

1. **Chroot:** `.chroot/` (about 1.8 GB, ignored via `.git/info/exclude`). Create it with
   `scripts/linux-chroot/setup.sh` (downloads the Ubuntu 24.04 base image, adds GCC 14 from the
   `ubuntu-toolchain-r/test` PPA, cmake, ninja, the GL/X11/pulse dev packages, and a venv at
   `/opt/autobuild` with autobuild 3.10.2 and llsd 1.2.4; a few minutes, needs a `/etc/subuid`
   range). It also installs `.chroot/enter [cmd]`, which runs a command in the chroot as your own
   user (root inside maps to you); the repo and `../fs-build-variables` (read-only) are mounted at
   their own paths. Tested from scratch: a clean chroot reports g++-14 14.3, cmake 3.28.3, ninja
   1.11.1, autobuild 3.10.2, and a full viewer build in it succeeds (2026-10-31, see step 2). `../fs-build-variables`
   must be cloned first (see the macOS section, step 1; the Xcode deployment-target edit is macOS-only).
2. **Build:**
   ```sh
   .chroot/enter bash -c 'autobuild configure -A 64 -c ReleaseFS_open -- --ninja --jobs 14 --chan=Alpha -DLL_TESTS:BOOL=FALSE &&
     autobuild build -A 64 -c ReleaseFS_open --no-configure -- --ninja --jobs 14 --chan=Alpha -DLL_TESTS:BOOL=FALSE'
   ```
   `--chan=Alpha` gives the channel `CompanionViewer-Alpha` (the name is prepended; don't pass
   `CompanionViewer`). Output: `build-linux-x86_64/newview/packaged/`. A change to a widely
   included header recompiles ~180 files.

   **Development builds: add `--no-package`** to both commands (it takes effect at configure
   time, as `PACKAGE:BOOL=OFF` in the CMake cache). `packaged/` is still filled, but the strip
   and `.tar.xz` steps are skipped, so the binary there keeps its debug info (~3 GB), which
   gives line numbers in `coredumpctl` backtraces. Reconfigure without it for a release tarball.
   The local install (step 3) is refreshed from a `--no-package` build; it is then about 3.7 GB.

   **Configure in a fresh build folder may fail once or twice** with `Could not find
   COLLADADOM_LIBRARY` or `NDOF_LIBRARY`, although the library was just downloaded into
   `build-linux-x86_64/packages/lib/release`. Re-running the same configure command picks it up;
   it passed on the third run on 2026-11-01.

   **A chroot can be copied** instead of recreated: `.chroot/enter` finds the repo from its own
   location. Copy it inside a user namespace so the subuid-owned files come along:
   `unshare --map-auto --map-root-user cp -a --reflink=auto <other-clone>/.chroot .chroot`.

   **Measured full build (2026-10-31, clean checkout and fresh chroot):** 15 min 19 s wall clock for
   the command above (configure, library downloads and the ~70 s CMake step included; 1358 ninja
   steps; packaging and the `.tar.xz` included), 0 errors, 0 warnings. Machine: Intel Core i7-14700K
   (20 cores / 28 threads, 5.6 GHz max), 31 GiB RAM, Samsung 990 PRO NVMe, CachyOS (kernel
   7.3.0) host, `--jobs 14`. Peak system RAM in use during the build was about 25 GiB (whole
   machine, desktop included), so 16 GB machines should lower `--jobs`. A shallow clone gives build
   number `.31` (`git rev-list --count HEAD`) instead of the upstream revision count; harmless.

   **Heat (same machine, 2026-11-01):** at the board's stock power limits (PL1 = PL2 = 253 W) a
   `--jobs 14` build reaches 98–100 °C and the CPU throttles. With both limits at 160 W it stays at
   85–88 °C without throttling, but the last steps, when only a few jobs run, still spike to 99 °C:
   a power limit doesn't restrain a few cores boosting to 5.5 GHz. A clean `--no-package` rebuild
   took 10 min 41 s with the limits at 160–175 W. With BIOS limits of 180 W and CPU Lite Load 12
   (down from 16) a clean `--no-package` rebuild took 10 min 24 s and was stable (0 compiler
   errors, 0 machine-check errors), but ran at 89–92 °C, peaked at 97 °C and throttled 154 times,
   mostly on the P-cores. With Lite Load 12, a 170 W cap and P-cores capped at 5.4 GHz
   (`cpupower frequency-set -u 5.4GHz`) the rebuild took 10 min 26 s at 86–91 °C, peaked at 93 °C
   and did not throttle; the only throttling (12 events) came in the last one-job steps after the
   cap had been raised back to 5.5 GHz. Limits set from Linux
   (`/sys/class/powercap/intel-rapl:0/constraint_{0,1}_power_limit_uw`, root) last until reboot;
   the lasting fix belongs in the BIOS (power limits, CPU Lite Load, a 90 °C temperature limit).
3. **Never run from `packaged/`.** Packaging deletes and recreates it, which breaks a running viewer
   (SSL CA errors, then a crash opening Preferences). Install a copy and run that:
   ```sh
   rsync -rptgoDLK --exclude='bin/.debug' build-linux-x86_64/newview/packaged/ ~/.local/opt/companionviewer-alpha/
   chmod 755 ~/.local/opt/companionviewer-alpha/bin/{dullahan_host,chrome-sandbox,SLVoice}
   ```
   Check no viewer is running before the rsync. The launcher is
   `~/.local/share/applications/companionviewer-alpha.desktop` (outside the repo).
4. **User data:** `~/.companionviewer` (override: `COMPANIONVIEWER_USER_DIR`). Log:
   `~/.companionviewer/logs/CompanionViewer.log`.

## Running several viewers
Work ported from the `multibox-memory` branch of `../multibox-memory` (cherry-picked, tags
`<FS:Luna Witch>`). Running several viewers at once is the reason for the memory work. Full
write-up (changes, settings table, measurements, open items, test procedure and test scripts,
macOS notes): [`doc/multibox-memory.md`](doc/multibox-memory.md).
- **Cache:** each instance locks the lowest free `instance_<n>.lock` in the base cache folder and
  uses `<cache>/<n+1>` as its own fully writable cache (texture, disk, object). This is applied in
  `LLDir::getCacheDir()`; `getCacheBaseDir()` is the unsuffixed path. Caches are deliberately not
  shared, so the second instance downloads what it needs. Only a 9th instance falls back to the
  base folder, read-only.
- **Instance-aware defaults:** the texture GPU budget and image-decode threads are divided by the
  number of running instances. A second instance sharing the user directory does not overwrite
  `settings.xml` on exit.
- **Memory:** bake-mask textures are not uploaded; vertex-buffer CPU copies are freed after 10 s
  (`FSVBOReleaseStagingSecs`); uploads go through a staging buffer (`FSVBOGPUCopyUpload`); freed
  heap pages return at once (`FSHeapDecayMs`); flexi prims, colour changes and scripted
  hide/show no longer rebuild whole attachments (`FSOctreeBridgeMoveSlack`,
  `FSInPlaceColorUpdates`); `FSVBOAllocTrace` is a debug trace.
- No launcher scripts or per-role profiles: the goal is one well-behaved cooperative viewer. To tell one instance
  from another, check `COMPANIONVIEWER_USER_DIR` in `/proc/<pid>/environ`.
- Check "show in place after a group rebuild" in-world with the test cube script in
  `doc/multibox-memory.md`.
- Working rules for tests (ask before launching a viewer, never edit a running launcher in place,
  abort cache moves if a viewer runs) are in that file's "Testing" section.

## New-install defaults
The tester's preference choices (double-click teleport, sound and mute toggles, 20 GB caches, chat
and radar options, RLVa on, ...) are the shipped defaults in `app_settings/settings.xml` and
`settings_per_account.xml`. Graphics and hardware tuning is left to the viewer's autodetection;
don't copy those from a used profile. A used profile's `settings.xml` lists only values that differ
from the defaults, but that includes autodetected and session state.

Radar (owner's decision): the only report on by default is someone entering chat range
(`RadarReportChatRangeEnter`), with its sound (`PlayModeUISndRadarChatEnter`). Every other radar
report and radar sound, the avatar age alert included, stays off.

Volumes (owner's decision): Master, UI, Media and Music are at 1.0 and enabled. Sounds, Ambient
and Voice are at 0 and muted (`MuteSounds`, `MuteAmbient`, `MuteVoice`). The typing sound is off
(`PlayModeUISndTyping` 0). The microphone level (`AudioLevelMic`, "My volume") is 0 for
privacy, and voice chat itself is disabled (`EnableVoiceChat` 0).

Maturity (owner's decision): everything is included. `PreferredMaturity` and
`FSSearchGroupMaturity` are 42 (Adult), and every `ShowPG*`, `ShowMature*` and `ShowAdult*` search
filter is on. Preferences clamps these down for accounts that can't access Mature or Adult.

Left at the upstream defaults on purpose (the tester's old profile differed): `ShowNewInventory`
on, `ForceShowGrid` off, `QAMode` off, and no frame-rate preset (`FramePerSecondLimit` stays as
shipped; frame-rate tuning is left to autodetection like other hardware settings), height in
metres (`HeightUnits` 1), case-sensitive script search (`LSLFindCaseInsensitivity` 0), and the stock
Do Not Disturb response (`DoNotDisturbModeResponse`).

Every alert in Preferences > Notifications > Alerts also starts hidden (unchecked). That default
is set in `LLNotificationForm` (`indra/llui/llnotifications.cpp`), not in a settings file; the
user's choices are saved in `user_settings/ignorable_dialogs.xml`.

Other places that hold defaults `settings.xml` does not:
- The viewer-mode file. A new install uses `app_settings/settings_firestorm.xml`, whose values
  replace the `settings.xml` defaults ("The session file turns into the new defaults" in
  `llappviewer.cpp`). `LetterKeysAffectsMovementNotFocusChatBar` is set to 1 there for this reason.
- `app_settings/key_bindings.xml`. Double-click on land to teleport is the `Double LMB` →
  `teleport_to` binding in `third_person`; `DoubleClickTeleport` alone doesn't turn it on.
- `skins/default/toolbars.xml`. The default toolbar layout is the tester's: icons on the right
  edge only, bottom and left toolbars empty. Each account saves its own copy in its per-account
  folder, so this only affects accounts that haven't customised theirs.

## Changes so far (the rebrand commits at the start of `dev`)
| Commit | Summary |
|---|---|
| `8ea1432c` | Rebrand to Companion Viewer: names, channel, packaging, English-only UI, Firestorm links/services hidden, new artwork, bundled login page |
| `9ad871dc` | macOS 12 deprecation fixes for Xcode 27 |
| `ac048202` | Package only English emoji names |
| `15edb188` | Bundled login page loaded as `file://` URL; default channel `CompanionViewer` |
| `91b88d32` | Ocean-blue, higher-contrast color scheme replacing Firestorm orange |
| `ef47ef0d` | MOTD and first-run Welcome Pack disabled; `_x64` removed from the user-facing app name |

Details worth knowing:
- **Artwork:** the source icon is `doc/companionviewer_icon.png`. App icons, installer art, the
  login logo and the Quick Prefs toolbar icon are generated from it (existing `firestorm_*`
  filenames kept).
- **Hidden Firestorm entry points:** Help-menu community links, "Message of the day" menu item,
  Guidebook, Report Problem, F1 and floater "?" help (`HelpURLFormat` empty, `FSHideHelpButtons`=1),
  FIRE- Jira auto-links, Windows AVX2 download prompts.
- **Login screen:** a self-contained page (black, centred logo, "Companion Viewer" in Syncopate) at
  `indra/newview/skins/default/html/en-us/login/index.html`. `FSPanelLogin` uses it whenever the
  grid's login page is a Firestorm-hosted URL, and loads it as an escaped `file://` URL (a bare
  path makes CEF fail). Font and its Apache-2.0 license are in `doc/fonts/syncopate/`.
- **Channel:** `scripts/configure_firestorm.sh` defaults to `CompanionViewer`; `--chan X` gives
  `CompanionViewer-X`.
- **Color scheme:** done in the default "Grey" theme of the `firestorm` skin (shown as "Companion
  Viewer").
  - `indra/newview/skins/firestorm/colors.xml`: `EmphasisColor` is a bright blue for text and links
    (#5CB8F2); the new `EmphasisBgColor` is a deep blue (#1F6BAD) for fills behind white text.
  - 95 orange UI textures from `skins/default/textures` were hue-shifted to blue, and the copies
    placed under `skins/firestorm/textures/`. The `default` skin's files are unchanged.
  - Warning, record, power, inventory, star and sun icons keep their colors.
  - Other themes (Dark, Blue, High Contrast, CtrlAltStudio) are not recolored.
  - Log In button (`skins/default/xui/en/panel_fs_nui_login.xml`, the active login panel): deep-blue
    `PushButton_Login*` images (white label ≥7:1 in every state), and when disabled a grey
    `PushButton_Disabled` image with a solid `LtGray` label.
- **MOTD:** all sources are off via `FSData::MOTD_ENABLED = false` (`indra/newview/fsdata.h`).
- **Avatar Welcome Pack:** no longer opens on first login; still reachable from the menu.
- **Rejected keystrokes are silent:** a character a box doesn't accept (letters in a number
  field, non-ASCII in an item name, ...) just doesn't appear. The "There was an invalid keystroke
  entered" tip is off in `Validator::showLastErrorUsingTimeout()` (`indra/llui/lltextvalidate.cpp`),
  and the `UISndBadKeystroke` sound is never played: not for text or number boxes
  (`LLUI::reportBadKeystroke()`, the slider/spinner `reportInvalidData()`), arrowing past the end
  of a list, or trying to fly where it isn't allowed. Its row in Preferences > Sound > UI Sounds is
  hidden and it is no longer preloaded. The notification, strings and setting are kept.
- **`_x64`:** `LLAppViewer::getSecondLifeTitle()` returns just "Companion Viewer". The user-data
  folder is also unsuffixed (`~/.companionviewer` on Linux; override with `COMPANIONVIEWER_USER_DIR`).
  Nothing migrates the old `_x64` folders. The OS cache folder name on macOS/Windows (`lldir.cpp`,
  `lldir_mac.cpp`) still has `_x64`.

## Open items
- **We need our own MOTD source** before turning `FSData::MOTD_ENABLED` back on. Don't point it
  at Firestorm servers again.
- Background data feeds (grid list, grid status, fsdata) still use Firestorm servers;
  `defaults.7.2.5.xml` from phoenixviewer.com returns 403 to this viewer.
- In-world screens haven't been reviewed in the new color scheme yet.
- Only the macOS build has been exercised in-world. The Linux build runs and logs in on
  Linux (COSMIC on Wayland, 2026-10-31; that run used an XWayland workaround that isn't committed).

## Next feature: LLM companion agent (planned, not started)
Full plan: [`doc/companion-agent-plan.md`](doc/companion-agent-plan.md). Summary:
- Connect the logged-in avatar to KoboldCPP or Ollama (local back ends). It hears chat, looks around,
  and comments on the world and other avatars.
- Uses **LEAP** (`indra/llcommon/llleap.cpp`): the viewer launches a helper (`--leap "<cmd>"`) that
  calls the viewer's existing event APIs (`indra/newview/*listener.cpp`) over stdin/stdout.
- Settled decisions (don't re-litigate):
  - **Rust helper.**
  - **No navigation:** body actions only.
  - **Vision:** 360 cube faces first; an aimed snapshot only for close-ups.
  - **LLM replies are drafted into the matching chat input, never sent:** the user reviews,
    edits and presses Enter.
  - **MVP:** a "give me my next line" button beside Send in nearby chat; one cycle drafts one line
    from recent chat (plus the sim view when chat refers to surroundings). The character comes from
    the avatar's own profile (Notes, First Life, Picks). Not a scripted agent.
- Viewer work needed: publish incoming chat and IMs to event pumps, add a `draftChat` op, and add
  a `captureCubeFaces` op refactored out of `LLFloater360Capture`.
