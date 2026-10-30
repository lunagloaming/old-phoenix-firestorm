# Companion Agent: connect an LLM (KoboldCPP / Claude / OpenAI) to the avatar

**Status (2026-10-30):** planned, not started. Repo `<repo>`, branch
`companion-rebrand` (last commit `34b937c0`). No code for this plan has been written yet.

## User decisions (binding — don't re-litigate)
- **Helper language: Rust.** The user can't stand Python; don't propose Python for helpers or
  tooling around this feature.
- **No navigation.** Movement in SL is as hard as IRL: pathfinding isn't generally available
  (region-side Havok, not on every platform/build, rarely set up by builders) and avatars snag on
  hit boxes. Autopilot/follow are out of scope; the agent stays in place and only uses body
  actions (sit when told, stand, turn to face, gestures).
- **Vision: 360 first.** "Look around" uses the 360 capture's cube faces (all directions,
  undistorted), not camera-limited screenshots. A single aimed shot is only for close-up detail.
- **Human in the loop for speech.** LLM output is never sent automatically: it is placed in the
  input box of the chat it belongs to (nearby chat, or that IM session) *without* pressing Enter,
  so the user can review, edit, and send it themselves.
- **Integration via LEAP**, the viewer's existing child-process plugin protocol; providers:
  KoboldCPP, Claude (Anthropic API), OpenAI.

## Context
The user wants the logged-in avatar driven by an LLM that can chat, "look around" and comment on
the world and on other avatars, and (stretch) move around. Exploration showed the viewer already
ships LEAP (`indra/llcommon/llleap.cpp`): it launches a child process and lets it call ~20 internal
event APIs over stdin/stdout. Almost everything the agent needs is already exposed:

| Need | Existing op (pump → op) | File |
|---|---|---|
| Speak | `LLChatBar` → `sendChat` exists, but **not used**: output goes through the new `draftChat` (step 1a) | `indra/newview/fsnearbychatbarlistener.cpp` |
| Who's around | `LLAgent` → `getNearbyAvatarsList` (id, name, region_pos, global_pos) | `indra/newview/llagentlistener.cpp:190` |
| Own position | `LLAgent` → `getPosition` | `llagentlistener.cpp:84` |
| Aim camera | `LLAgent` → `setCameraParams` / `removeCameraParams` (locked camera_pos + focus_pos) | `llagentlistener.cpp:148` |
| See | `LLViewerWindow` → `saveSnapshot` (filename, width, height, showui, showhud) | `indra/newview/llviewerwindowlistener.cpp:56` |
| Body | `requestSit`/`requestStand`, `lookAt`, `resetAxes` (turn), `playAnimation`, `LLGesture` | `llagentlistener.cpp` |
| Subscribe to events | LEAP control pump → `listen` | `indra/llcommon/llleaplistener.cpp:73` |

**Out of scope: navigation.** The autopilot ops exist (`startAutoPilot`, `startFollowPilot`) but
only steer in a straight line; SL pathfinding is not generally available (region-side Havok,
not on every build/platform, rarely set up by builders) and avatars snag on hit boxes. The agent
stays in place and only uses body actions (sit when told, stand, turn to face, gestures).

The one missing piece is **hearing**: incoming chat is never posted to an event pump, so a
helper can talk but not listen.

Wire format (confirmed in `llleap.cpp`): frames are `<len>:<llsd>`; viewer→helper is binary LLSD
with header, helper→viewer must be LLSD notation. Envelope `{pump, data}`; first message from the
viewer carries the helper's reply pump and the control pump name.

## Plan

### 1. Viewer: publish incoming chat (small C++ change)
- In `process_chat_from_simulator` (`indra/newview/llviewermessage.cpp`, where
  `LLNotificationManager::instance().onChat(chat, args)` is called, ~line 3401, i.e. after mute,
  anti-spam and RLVa filtering), post to an `LLEventStream` pump `"LLNearbyChat"`:
  `{from, from_id, owner_id, source_type: agent|object|system, chat_type: say|whisper|shout|...,
  message, region_pos}`. Skip typing start/stop. Name matches LL's newer viewers for compatibility.
- Also post incoming IMs from `process_improved_im` (`llviewermessage.cpp:2500`) to `"LLIMMessages"`
  `{from, from_id, session_id, message}` so the owner can command the agent privately.
- Mark with `// Companion Viewer:` comments like the existing changes.

### 1a. Viewer: draft text into a chat input (new function + op)
Nothing exposed today can fill a chat input without sending. Building blocks:
`FSNearbyChat::showDefaultChatBar(visible, text)` (`indra/newview/fsnearbychathub.cpp:327`) shows
the main chat bar with text; the nearby chat floater has `FSFloaterNearbyChat::getChatBox()`;
IM windows (`FSFloaterIM`, `indra/newview/fsfloaterim.h`) keep `mInputEditor` private.
- Add `FSNearbyChat::setDraftText(const std::string&)` — fills the nearby input the user last
  used (the hub already tracks the focused input via `setFocusedInputEditor`), falling back to
  the default chat bar, making it visible if hidden.
- Add `FSFloaterIM::setDraftText(const std::string&)` — fills `mInputEditor`; callers get the
  floater with `FSFloaterIM::show(session_id)` (opens the session window if needed).
- Both: set text and move the cursor to the end; **never send**, and don't take keyboard focus
  (optional `focus` arg) so the user isn't interrupted mid-typing elsewhere. Don't clobber the
  user's own unsent text: replace only if the input is empty or still holds the previous agent
  draft unchanged; otherwise reply `busy` and let the helper keep the draft and retry later.
- Expose as `LLChatBar` → `draftChat` (in `indra/newview/fsnearbychatbarlistener.cpp`):
  args `message`, optional `session_id` (IM; omitted = nearby chat), `focus`.
  Replies `{ok}` or `{ok:false, reason:"busy"|"no_session"}`.

### 1b. Viewer: 360 "look around" op (reuse the 360 capture renderer)
`LLFloater360Capture::capture360Images()` (`indra/newview/llfloater360capture.cpp:453`) renders six
90° cube faces (`gViewerWindow->simpleSnapshot` per `lookDir`) and only then stitches an
equirectangular image in the floater's CEF page. For an LLM the undistorted faces are better than
the stitched panorama (no polar stretching; detail survives downscaling), and they need no
browser or Save dialog.
- Extract the face loop (camera save/restore, aspect 1 + 90° FoV, occlusion off, `freezeWorld`,
  optional hide-avatars, `simpleSnapshot` ×6) into a free function, e.g.
  `capture_cube_faces(origin, yaw, size, faces, hide_avatars) -> std::array<LLPointer<LLImageRaw>,6>`,
  and have the floater call it (no behaviour change for the 360 floater).
- Expose it as `LLViewerWindow` → `captureCubeFaces` in `llviewerwindowlistener.cpp`:
  args `dir`, `size` (default 768), `faces` (default front/right/back/left/down),
  `origin` (default: avatar eye position), `align_to_avatar` (rotate so "front" = avatar heading).
  Writes one JPEG per face, replies `{ok, files: {front: path, ...}, heading_deg}`.

### 2. Helper: `indra/newview/companion_agent/` (Rust, Cargo crate, tokio)
Standalone binary `companion-agent`, built with `cargo build --release` (not part of the CMake
build yet). Cross-platform (macOS/Windows/Linux). Crates: `tokio`, `serde`/`serde_json`,
`reqwest` (rustls), `image` (downscale + JPEG), `base64`, `anyhow`, `tracing` (to stderr).
Modules:
- `llsd.rs` — minimal LLSD: binary parser (viewer→helper, with the `<? LLSD/Binary ?>` header) and
  notation writer (helper→viewer); `Llsd` enum ↔ `serde_json::Value` conversion. Small, so
  hand-written with round-trip unit tests rather than depending on an unmaintained crate.
- `leap.rs` — `<len>:<payload>` framing on stdin/stdout, handshake (reply pump + control pump),
  `request(pump, op, args) -> reply` matched by `reqid` via a pending-oneshot map, `listen(pump)`
  returning an event stream. stderr lines land in the viewer log.
- `viewer.rs` — typed async wrappers: `draft(target, text)`, `nearby_avatars`, `position`, `look_around`,
  `look_at(avatar)`, `sit`, `stand`, `face(avatar)`, `gesture`.
  - `look_around` (default vision): `captureCubeFaces` from the avatar's eye point; send the
    faces as separate images labelled front/right/back/left/down relative to the avatar, plus
    the nearby-avatar list with bearings so the model can tie names to what it sees.
  - `look_at(avatar)` (close-up detail, e.g. "what do I look like?"): camera point ~2.5 m from
    the target facing it (focus at head height), `setCameraParams` locked, wait ~1.5 s for
    textures, `saveSnapshot` (1024×768, no UI/HUD), `removeCameraParams`.
  - Downscale/re-encode before upload.
- `llm/` — `trait Provider { async fn chat(&self, msgs, images, tools) -> Reply }`, two impls over
  plain `reqwest` + serde types:
  - `openai.rs` — Chat Completions format: OpenAI, and KoboldCPP at `http://localhost:5001/v1`
    (vision needs a model loaded with its mmproj).
  - `anthropic.rs` — Messages API with image blocks + tool use; default model
    `claude-opus-5-5`, configurable.
  - Fallback "no tools" mode for local models with weak tool calling: attach a fresh `look` when
    asked about appearance; plain-text replies only.
- `agent.rs` — event loop:
  - Triggers: chat that mentions the avatar's name (default), IM from the owner, optional
    ambient mode (comment every N minutes when people are near).
  - Context: rolling transcript of nearby chat, nearby avatar names + distances, region name,
    persona prompt.
  - Tools for the model: `look_around()`, `look_at(avatar)`, `reply(text)` (→ `draftChat` into the chat the trigger came from: nearby or that IM session), `face(avatar)`, `gesture(name)`, and
    owner-only `sit(target)` / `stand()`.
  - The helper never calls `sendChat`; on `busy` it keeps only the newest draft and retries
    when the input is free.
  - Guardrails: reply rate limit, max message length (SL chat limit 1024 bytes), cooldown,
    "stop"/"quiet" kill word from owner, never act on chat from objects.
- `main.rs` + `config.rs` — config at
  `~/Library/Application Support/CompanionViewer/companion_agent.json` (provider, model, base_url,
  persona, trigger mode, owner name); API keys from env vars (`ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`) or the file (created 0600). Keys never go in viewer settings.

### 3. Launch
- Development: `--leap "indra/newview/companion_agent/target/release/companion-agent"`.
- Later (separate step): build it from CMake, bundle it in the app and add a menu toggle that starts/stops it
  via `LLLeap::create` (same as `llappviewer.cpp:1388`). Keep `LeapCommand` non-persistent so
  settings can't be used to launch arbitrary programs.

### Notes for the user
- Second Life policy requires accounts run by automation to be flagged as **Scripted Agents**;
  using a dedicated bot account is recommended.
- Snapshots of other residents go to the chosen provider; KoboldCPP keeps everything local.

## Verification
1. `cargo test`: LLSD binary-parse / notation-write round trips (including samples captured from
   the viewer), framing split across reads, reqid reply matching.
2. Build the viewer; launch with `--leap` running `companion-agent --smoke`, which calls
   `getAPIs`, prints `getNearbyAvatarsList`, `draftChat`s "hello" into nearby chat and an open IM (text appears, nothing is sent; typing
   your own text first → `busy`, not overwritten), and logs `LLNearbyChat` events —
   verify in the viewer log and chat.
3. With the full agent on a quiet sandbox region and a second account: address the avatar by name
   → it replies; ask "what do I look like?" → it looks at the speaker and describes them; "what's
   around here?" → `captureCubeFaces` faces appear in the temp dir and it describes the
   surroundings in all directions (also confirm the 360 floater still captures and saves as before); owner IM "quiet" silences it. Repeat with each
   provider (KoboldCPP, Anthropic, OpenAI).
