# AGENTS.md — Companion Viewer

Notes for coding agents (and humans) resuming work on this repo from any machine.

## What this is
Companion Viewer is a fork of the Firestorm Second Life viewer (tag
`Firestorm_Release_7.2.5.81788`), rebranded as **"Companion Viewer"** (display name) /
**`CompanionViewer`** (files, channel, folders, binaries). It is not affiliated with or supported
by the Firestorm project. All work so far is on branch **`companion-rebrand`** (base: `main`).

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

## Changes so far (branch `companion-rebrand`)
| Commit | Summary |
|---|---|
| `fb215341` | Rebrand to Companion Viewer: names, channel, packaging, English-only UI, Firestorm links/services hidden, new artwork, bundled login page |
| `e60685d0` | macOS 12 deprecation fixes for Xcode 27 |
| `2a0b2c12` | Package only English emoji names |
| `4e122384` | Bundled login page loaded as `file://` URL; default channel `CompanionViewer` |
| `5cf7cb42` | Ocean-blue, higher-contrast color scheme replacing Firestorm orange |
| `34b937c0` | MOTD and first-run Welcome Pack disabled; `_x64` removed from the user-facing app name |

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
- Only the macOS build has been exercised.

## Next feature: LLM companion agent (planned, not started)
Full plan: [`doc/companion-agent-plan.md`](doc/companion-agent-plan.md). Summary:
- Connect the logged-in avatar to KoboldCPP, Claude or OpenAI. It hears chat, looks around,
  and comments on the world and other avatars.
- Uses **LEAP** (`indra/llcommon/llleap.cpp`): the viewer launches a helper (`--leap "<cmd>"`) that
  calls the viewer's existing event APIs (`indra/newview/*listener.cpp`) over stdin/stdout.
- Settled decisions (don't re-litigate):
  - **Rust helper.**
  - **No navigation:** body actions only.
  - **Vision:** 360 cube faces first; an aimed snapshot only for close-ups.
  - **LLM replies are drafted into the matching chat input, never sent:** the user reviews,
    edits and presses Enter.
- Viewer work needed: publish incoming chat and IMs to event pumps, add a `draftChat` op, and add
  a `captureCubeFaces` op refactored out of `LLFloater360Capture`.
