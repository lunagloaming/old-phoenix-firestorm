# Companion Agent: connect a local LLM (KoboldCPP or Ollama) to the avatar

**Status (2026-10-30):** planned, not started. Repo `<repo>`, branch `dev`; the plan was
written on top of the rebrand (`ef47ef0d`). No code for this plan has been written yet.

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
- **Integration via LEAP**, the viewer's existing child-process plugin protocol; back ends:
  **KoboldCPP or Ollama** (both local; updated 2026-10-30). Claude (Anthropic API) and OpenAI are not
  planned; the provider trait below keeps them possible later. SillyTavern is not a back end or a
  dependency; we only borrow its prompt-structure ideas (see the persona section).

## MVP scope (stated by the user 2026-10-30)
- We are an ordinary user of a viewer, using chat completion and exploring what comes of it. This is
  **not** a scripted agent or bot, so there is no Scripted Agent registration work for now.
- **The loop:** listen to open (nearby) chat, then suggest the avatar's own next line by **pre-filling
  the chat box**. The user edits it and presses Enter. Then repeat.
- **Turn-taking is the user's call: a "give me my next line" button** beside the Send button in the
  nearby-chat window. Pressing it starts one cycle (gather recent chat, look if needed, ask the model,
  draft the reply). There is no automatic "everyone has had a turn" logic.
- **Being addressed by name is not a separate feature.** A chat line that names the avatar can start
  the same cycle automatically (or just show the button as highlighted; choose when building). Either
  way the result is the same: text offered in the chat box for the user to edit and submit.
- **The sim view is context, and it makes the MVP harder than it sounds.** When people refer to
  things around them ("that dress", "over there", "who's that?"), the model needs to see the
  surroundings to follow. That means deciding when to look (a tool the model calls, or a heuristic
  in the no-tools fallback), and attaching the cube faces (and the nearby-avatar list) to that turn.
- Not in the MVP: IM sessions, ambient comments, body actions, the shop-browsing agent loop below
  (that is the later, richer version).
- **Viewer work this adds (step 1c):** the button in the nearby-chat window (XUI in
  `floater_fs_nearby_chat.xml` plus a C++ handler) that posts a "suggest" event to the helper's
  LEAP pump. If the chat box already holds text the user typed, the draft must not overwrite it
  (`draftChat` returns `busy`, as already planned); the button can be disabled or the request
  skipped in that case.
- The other triggers in the plan below (IMs from the owner, ambient mode) are post-MVP.

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
- `llm/` — `trait Provider { async fn chat(&self, msgs, images, tools) -> Reply }`, one impl is enough for the
  planned back ends, over plain `reqwest` + serde types:
  - `openai.rs` — Chat Completions format, which both speak: KoboldCPP at
    `http://localhost:5001/v1` (vision needs a model loaded with its mmproj) and Ollama at
    `http://localhost:11434/v1` (vision needs a multimodal model, such as the Qwen-VL or Gemma
    families; check which models and image inputs the installed Ollama version accepts).
    `base_url` and `model` are config, so the same code serves either; it would also serve OpenAI.
  - `anthropic.rs` — not planned. A Messages API client with image blocks and tool use could be
    added behind the same trait if wanted.
  - Fallback "no tools" mode for local models with weak tool calling: attach a fresh `look` when
    asked about appearance; plain-text replies only.
- `agent.rs` — event loop:
  - Triggers: the "give me my next line" button (MVP; chat that names the avatar may start the same
    cycle), then later IM from the owner and optional ambient mode (comment every N minutes when
    people are near).
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
  persona, trigger mode, owner name); local back ends need no key. If a hosted provider is added,
  keys come from env vars or the file (created 0600) and never go in viewer settings.

### 3. Launch
- Development: `--leap "indra/newview/companion_agent/target/release/companion-agent"`.
- Later (separate step): build it from CMake, bundle it in the app and add a menu toggle that starts/stops it
  via `LLLeap::create` (same as `llappviewer.cpp:1388`). Keep `LeapCommand` non-persistent so
  settings can't be used to launch arbitrary programs.

### Notes for the user
- This is not a scripted agent (not a bot): it is a normal viewer driven by its user, who reviews
  and sends every line. No Scripted Agent registration applies for now; revisit only if that changes
  (for example if lines were ever sent without the user).
- Snapshots of other residents go to the back end; KoboldCPP and Ollama on this machine keep everything local.

## Persona and context from the avatar's own profile (stated by the user 2026-10-30)
The character's definition lives in the logged-in avatar's profile, so it is edited in-world with the
normal profile editor and travels with the avatar. **Send three profile fields as context:**
1. **Notes tab:** the main one. Anything the user wants the model to know or obey: character
   details, how to speak, things to avoid, standing instructions.
2. **First Life tab:** more background about the character (the user may put some character details here too).
3. **Picks:** each pick's name, description and place (sim name) as interests, favourite places and
   background colour.

(The viewer already holds all of this in `LLAvatarData` (`notes`, `fl_about_text`, `about_text`,
the picks list) and `LLPickData` (`name`, `desc`, `sim_name`) in `llavatarpropertiesprocessor.h`.
No listener exposes them to LEAP yet; this needs a small new op, **step 1d: `getOwnProfile`**,
returning the notes, first-life text, about text and picks of the logged-in avatar, and an event when
they change so the helper can refresh. To verify when building: that the Notes tab text for one's
own avatar is populated and fetchable, and that long text is not truncated.)

### How to structure the prompt (borrowing SillyTavern's ideas)
SillyTavern builds a prompt from a character card plus ordered, injectable sections. We do not use
SillyTavern; we build the prompt ourselves in the Rust helper and send it to KoboldCPP or Ollama.
Map the same ideas onto our sources, so each piece has one place and one budget:

| SillyTavern idea (as an analogy) | Our source |
|---|---|
| System prompt / instructions | built-in default ("you suggest the next line for this avatar in local chat; one short in-character line; never claim to be the user's real self") plus any instruction-style text in Notes |
| Character description / personality | Notes tab |
| Backstory / scenario background | First Life tab |
| Interests and places (like lorebook flavour) | Picks (name + description + place) |
| Scenario (the current situation) | live: region name, parcel, time, nearby avatars with distances and bearings |
| Example dialogue | optional lines in Notes under a marked heading (see below) |
| Chat history | rolling transcript of nearby chat, newest last |
| Author's note / depth injection | a short reminder re-inserted near the end of the prompt each turn ("reply as <name>, one or two short lines") so long chats don't drift |
| Lorebook / world info (keyword-triggered entries) | later: Picks or marked Notes entries injected only when their keywords appear in recent chat, to save context |
| Images | cube faces only on turns where chat refers to surroundings (see MVP scope) |

**Suggested order** (stable prefix first, so back ends that cache the prompt prefix can reuse it): system
prompt, Notes, First Life, Picks, example dialogue, then the changing parts: scenario, nearby avatars,
recent chat, images, author's note, and the request to draft the next line.

**Light structure inside the Notes tab (optional).** Plain prose works; for more control the helper can
recognise a few headings if present, for example `## Instructions`, `## Personality`,
`## Example dialogue`, `## Avoid`, and treat everything else as description. No heading is
required; unmarked text is just character details. Decide the exact marker syntax when building.

**Budget and limits.**
- Each field has a character cap and is trimmed from the end, with Notes taking priority, then First
  Life, then Picks. Local models have small contexts, so the caps are settings.
- Re-read the profile only when it changes (the event in 1d), not every turn.
- **Privacy:** profile text goes to the back end. These are the user's own words about their own
  avatar, but anything private in Notes is sent too. KoboldCPP and Ollama keep it on this machine; say so in the settings UI if a hosted back end is ever added.
- Profile text is instructions from the user, but treat chat from other residents as untrusted
  input: it must not be able to change the persona or the standing instructions.

## Design refinements from an outside discussion (proposals, not decisions)
Summary of a conversation with another assistant (2026-10-30), recorded for when we start work.
Nothing here is built, and nothing here overrides the binding decisions at the top. The scenario
that drove it: the avatar is in a hair shop, looks around on its own, identifies the styles on
sale and picks the one it likes. It does not walk or buy; the user does that.

**Core idea: an agent with senses, not a chatbot with pictures.** Don't hand the model every
image and ask for a verdict (small local models do badly at that). Give it tools and run a loop:
the helper sends the current observation plus the model's own notes, the model answers with one
action, the helper carries it out and returns the result, and it repeats until the model chooses.
KoboldCPP can run this with a vision-language model plus `--mmproj` (Ollama with a multimodal model); Qwen-VL and Gemma-family
models were named as strong at reading text and locating things in images.

**Proposed tools**, and how each maps onto the plan above:

| Proposed | Meaning | Relation to this plan |
|---|---|---|
| `survey()` | the cube faces, labelled front/right/back/left (up/down usually skipped indoors) | our `look_around`; add the grid overlay below |
| `look(direction, cell, zoom)` | close-up aimed at a grid cell on one face | new: generalises `look_at(avatar)` to an aimed camera (yaw/pitch/zoom) |
| `identify(direction, cell)` | name and hovertext of the object under that cell | new viewer op: a pick/raycast through a cell; feasibility not yet checked |
| `note(text)` | add to a scratchpad | helper-side only |
| `say(text)` | local chat | must go through `draftChat`, never sent automatically (binding decision) |
| `choose(candidate_id, why)` | final pick, handed to the user | helper-side; the user does any purchase |

**Four details that make it work:**
1. **Labelled cube faces, not a stitched panorama.** Six normal-perspective images are handled far
   better than one distorted equirectangular image. About 512–768 px per face is enough for a survey.
2. **Numbered grid overlay on every image** (set-of-mark prompting). Models are unreliable at pixel
   coordinates but good at "front face, cell C4". The helper converts a cell to camera yaw/pitch for
   the close-up, and the pick gives an exact handoff ("the vendor at back C4").
3. **Use the world's own labels.** Objects have names and hovertext. A pick through the camera gives
   the product name (for example "Brand Hair - Ivy (Fatpack)"), which combined with the text on the
   vendor image turns "a brownish wavy one" into an actual product.
4. **A scratchpad instead of a growing pile of images.** After each close-up the model writes a short
   note (candidate id, place, description, reaction) and the image is dropped from context. Rule:
   no `choose()` until at least three candidates are noted.

**Self-determination.** The model has no stable tastes by itself; asked twice it may pick differently.
To make taste coherent:
- give the persona a few concrete aesthetic lines (colours it gravitates to, how it sees itself,
  vibes it dislikes), not only a personality
- have it explain each pick in its own words and store that in long-term memory, then feed those
  memories back on later trips, so it can cite and build on past choices

**One model or two.** Start with a single vision model as both eyes and mind. Splitting (a vision
model describes, a separate chat persona decides) keeps an existing character voice but loses detail,
because the persona never saw the item. Split only if the voice suffers.

**Latency.** Each look-and-think cycle on local hardware may take several seconds, so a full shop
browse may take minutes. Acceptable; have it draft an occasional remark so it doesn't seem frozen.

**Memory and privacy.** Keep persistent memory scoped to the owner (and anyone they name), not to
bystanders who don't know they're talking to an AI. Disclose the AI in the avatar's profile.

**Points from that conversation we are not adopting:**
- **Python bridge.** It offered one; helpers are Rust (binding decision).
- **A headless bot (LibreMetaverse) and movement commands** (follow, sit, go to). We drive a real,
  rendering viewer through LEAP, so we already have eyes and a camera, and navigation is out of scope.
- **An in-world scripted relay** as a first step. It can't see or look around, so it doesn't serve this plan.

**Claim in that conversation not verified:** that Linden Lab's Convai-based "Character Designer" AI
characters were paused on 2025-09-01. It does not affect this plan. Its scripted-agent policy advice
does not apply while a human sends every line (see "Notes for the user").

**Open questions:**
- Can the existing pick code return an object's name and hovertext for an arbitrary screen point or
  ray, and is it reachable from LEAP (`captureCubeFaces` and an aimed camera are already planned)?
- Which local vision models give good enough shop-vendor text reading at 512–768 px per face?
- How should the scratchpad and long-term taste memory be stored (file per owner under the data folder)?

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
   back end (KoboldCPP, Ollama).
