# Running several viewers: memory work

Ported from the `multibox-memory` branch of the Firestorm fork (`../multibox-memory`, code tagged
`<FS:Luna Witch>`). That repository is no longer needed to understand this work: its README and
AGENTS.md are folded into this file. The instance-slot design differs from the original; see
"Instance slots" below.

**Intent:** one well-behaved, cooperative viewer: it uses memory frugally on its own, and it plays
fair when other viewers run beside it on the same machine (Linux first). **Memory comes first.**

What prompted it:
- On a 32 GB machine, each viewer reached about 10 GB within a minute of arriving in a crowded region.
- Together they pushed about 25 GB of viewer memory into zram swap, and neither viewer noticed: free
  memory still *looked* fine.
- GPU memory was nearly full, because each instance budgets as if it owns the whole GPU.

A single-process, multi-session viewer was considered and rejected. Session state is global
throughout the code (hundreds of singletons and globals), so it would mean rewriting most of the
viewer. These changes get the practical benefits across separate processes instead.

## Changes

**Phase 1: safety and memory awareness**
- **Texture cache, read-only instance:** it no longer shows the wrong texture when the owning
  instance has reused a cache slot (the fast cache is covered too), never deletes texture files from
  a cache it doesn't own, and re-reads the cache index after a miss. In Companion Viewer this only
  matters for an instance that finds no free slot and falls back to the shared base folder.
- **Linux memory pressure:** the kernel's pressure figure (`/proc/pressure/memory`) triggers texture
  downscaling. With compressed swap, free memory alone can look fine while the system thrashes.
- **Disk cache:** whole asset files are written to a temporary name and renamed into place, so no
  instance reads a half-written file.
- **Diagnostics:** viewer and thread-pool threads are named on Linux (`ps -L`, `top -H`).

**Phase 2: instance slots** (Companion Viewer's version)
- Each viewer locks the lowest free `instance_<n>.lock` in the base cache folder and uses
  `<cache>/<n+1>` as its own fully writable cache (texture, disk, object). Applied in
  `LLDir::getCacheDir()`; `getCacheBaseDir()` is the unsuffixed path. Only a 9th instance falls back
  to the base folder, read-only.
- **Difference from the original branch:** there, slot 0 owned one shared cache and the others read
  it read-only, with a per-slot `objectcache_<n>`. That let the second instance reuse textures the
  first had cached. Companion Viewer deliberately does not share caches, so instances never fight
  over cache files, at the price that the second instance downloads what it needs itself.
- **Instance-aware defaults:** the autodetected texture GPU budget and the automatic image-decode
  thread count are divided by the number of running instances. Explicit settings are left alone.
- **Settings on exit:** a second instance sharing the user directory skips the final write of
  `settings.xml`. The earlier "save settings at start of shutdown" step still writes it, so in
  practice the instance that exits last wins, as in stock Firestorm. Changes made in Preferences are
  saved when it is closed with OK, and per-account settings have their own file per avatar.

**Phase 3: memory footprint** (found by heap profiling)
- **Avatar bake masks:** they were uploaded as GL textures nothing draws with, and one path leaked
  them. The upload is skipped, saving about 1 GB of driver memory in a crowd, and GPU memory.
- **Vertex buffer CPU copies:** every vertex and index buffer kept a system-memory copy for its whole
  lifetime. The copy is freed once a buffer has gone unchanged for 10 seconds, and read back from the
  GPU if the buffer changes again.
- **GPU-copy uploads:** geometry goes through a small staging buffer and a GPU-side copy. Scenes load
  noticeably faster. In a standalone test it also stopped the NVIDIA driver keeping its own system
  copy of every buffer, but in the viewer that saved only a few hundred MB.
- **Geometry rebuilds:** when anything about an object changes, the viewer rebuilds its whole spatial
  group (for an attachment, usually the whole attachment) into new vertex buffers, and every new
  buffer makes the NVIDIA driver reserve memory again. Three causes dominated in a crowd:
  - **Flexi prims in attachments:** a swaying flexi prim near an octree node boundary crossed it back
    and forth, and every crossing rebuilt both nodes. Objects in attachments, moving linksets and
    animesh now stay in their node until well outside it (`FSOctreeBridgeMoveSlack`). One avatar's
    flexi tail went from about 800 rebuilds a minute per group to about 100.
  - **Colour changes:** every change (and, since a 2022 Linden fix, even a plain tint) rebuilt the
    whole group. A change that leaves a face in the same render batch now updates its vertex colours
    in place (`FSInPlaceColorUpdates`).
  - **Scripted hide/show ("flipbook" animations):** hiding a face (alpha 0) keeps it in its batch
    with degenerate triangles, and showing it restores it in place when the batch still fits. A group
    rebuild within 10 seconds of a hide keeps the face batched, so sibling faces don't keep dropping
    each other out.
- **Allocator page return (Linux):** the NVIDIA driver reserves heap memory the size of every vertex
  buffer it creates and never writes most of it. jemalloc's default of keeping freed pages for 10
  seconds let those reservations land on already-resident pages. Freed pages are now returned at once
  (`FSHeapDecayMs`), saving about 0.8 GB per viewer in a crowd with no measurable frame-rate cost.

**Not taken from the original branch:** its launcher scripts, which started differently tuned
instances with session-only `--set` overrides, and the login-screen notice (`FSMultiBoxProfile`)
that named the tuning profile in use. Companion Viewer has no per-role profiles; every instance runs
with the same defaults. The Linux wrapper still honours `FS_JEMALLOC_LIB` (use another jemalloc, e.g. one built with heap
profiling). Since the 7.3 rebase it no longer sets `__GL_THREADED_OPTIMIZATIONS`, so a caller's value
applies and the driver default (off) otherwise.

## Settings

| Setting | Default | Purpose |
|---|---|---|
| `FSReadOnlyCacheRefreshSecs` | 15 | Minimum interval between index re-reads in a read-only texture cache (0 disables) |
| `FSLinuxMemPressureThreshold` | 2.0 | `/proc/pressure/memory` "some avg10" percentage treated as low memory (0 disables) |
| `FSVBOReleaseStagingSecs` | 10 | Free the CPU copy of a vertex/index buffer after this many seconds unchanged; read back from the GPU if it changes again (0 keeps every copy; not used on Apple GPUs) |
| `FSVBOGPUCopyUpload` | on | Upload vertex/index data through a staging buffer and a GPU copy rather than directly (not used on Apple GPUs) |
| `FSHeapDecayMs` | 0 | Linux with jemalloc: milliseconds freed pages stay with the allocator before going back to the system (negative leaves jemalloc's own setting) |
| `FSInPlaceColorUpdates` | on | Update a face's colour or alpha in its existing vertex buffer when it stays in the same render batch, and hide or show faces in place, instead of rebuilding the object's whole group. Off restores the original behaviour |
| `FSOctreeBridgeMoveSlack` | 1 | How far, in multiples of its octree node's half size, an object in an attachment, moving linkset or animesh may move outside its node before it is moved to another one (each move rebuilds both nodes' geometry). 0 restores the original behaviour |
| `FSVBOAllocTrace` | off | Debug, not saved: log once a minute how much heap the GL driver allocates and frees inside the vertex buffer pool's GL calls (with a size histogram), jemalloc totals next to the process's RSS and swap, and the call stacks that write the most upload data (Linux with jemalloc; run with `__GL_THREADED_OPTIMIZATIONS=0`). Also logs which object groups rebuild their geometry (`RebuildTrace`) |

## Status

Measured on the original branch (Linux, i7-14700K, 32 GB RAM with zram swap, RTX 4090, driver 615),
two instances in a crowded region; **not yet re-measured in Companion Viewer**. Runtime-tested there:
instance slots, the read-only instance picking up the other's textures, the memory-pressure trigger
(with zram it rarely passes 10%, hence the 2% default), and an evening of dogfooding with no crashes.

**Memory, one viewer in a crowded region** (jemalloc heap profiles):

| | Start (unmodified) | Now |
|---|---|---|
| Live heap after about 12 minutes | about 18 GB | about 8.4 GB |
| Viewer's CPU copies of vertex buffers | 3.4–4.1 GB | under 0.1 GB |
| Avatar bake mask textures (driver memory) | about 1 GB | about 1 MB |
| NVIDIA driver memory, other | 4–6 GB | about 3.7 GB |
| Mesh/prim geometry (`LLVolumeFace`) | 2.7–4.5 GB | about 2.8 GB |

The runs differ in crowd size and settings, so the totals are indicative; the per-item figures are
the reliable ones. Returning freed pages at once saves a further ~0.8 GB (two 13-minute runs at the
same spot, ~75 avatars, differing only in that setting).

**Geometry rebuilt into new buffers** (`RebuildTrace`, ~70 avatars, minutes 2–13 of 13-minute runs):

| | Before | Now |
|---|---|---|
| Volume geometry rebuilt per minute | 0.8–2 GB | 0.3–0.7 GB |
| Share of it in other avatars' attachments | about 90% | about 90% |
| Scripted "shows" (alpha 0 → visible) done in place | none | 55–60% |
| Worst single attachment (flexi) | ~800 rebuilds/min per group, ~500 MB/min | ~100 rebuilds/min, ~20–90 MB/min |

The 55–60% was measured before a fix for faces that were shown in place after a group rebuild but
stayed invisible (holes, seen in a card-game HUD), so it needs re-measuring.

### Still open
- **Most of the NVIDIA driver's memory remains:** about 3.5 GB reserved when a buffer is created.
  `glBufferStorage` is untried.
- **Geometry rebuilds that remain:** the other ~40% of scripted shows, a sculpty rebuild loop that
  bursts to 11–14k requests a minute (`LLVOVolume::updateTextureVirtualSize` called from
  `rebuildGeom`, which queues another rebuild), material and texture changes, and LOD changes.
- **Avatar body meshes:** for the first ten minutes after arriving in a crowd, the system body meshes
  are rewritten about 9–10 GB a minute, probably even when hidden under mesh bodies. Skipping updates
  to hidden body parts is the likely fix.
- **Mesh geometry** is now the largest item in the viewer's own memory; reducing what is held for
  avatars that aren't fully rendered is possible future work.
- **An unattributed `operator delete[]` entry**, about 0.8 GB.
- **GPU budgets:** instances still exceed their texture GPU-memory budget by several GB, because the
  budget covers only textures.
- Possible later work: idle scheduling priority for housekeeping threads such as cache purging;
  per-thread-pool placement on performance or efficiency cores.

### Known issues not caused by this work
- **Expected once:** on first launch against caches written by an official build, the texture cache
  is purged, because this build decodes with OpenJPEG instead of KDU.
- **Avatars missing all attachments until a scene reload** (for example by dropping and restoring
  draw distance) is the long-standing SL object-update problem.
- **A mesh door renders broken from behind in unmodified Firestorm `master` builds as well**, but not
  in the 7.2.4 release: an upstream change or the OpenJPEG decoder.

## Findings (Linux, NVIDIA)

- **Where a crowded region's memory goes:** geometry held several times over: the viewer's mesh/prim
  data (`LLVolumeFace`), its CPU copy of every vertex buffer (now freed after 10 s unchanged), NVIDIA
  driver memory, and the GPU copy itself. **Textures are not the problem.**
- **Uploads:** standalone, NVIDIA keeps a system-memory copy of data uploaded with `glBufferSubData`
  or `glBufferData(data)`, but not of data written by `glCopyBufferSubData`. Uploads now go through a
  staging buffer, which is 2–4× faster, but in the viewer it only cut driver memory from 4.06 to
  3.65 GB.
- **Buffer creation:** `glBufferData(NULL)` makes the driver *malloc* about 1.2× the buffer's size as
  a reservation, about 3.5 GB live in a crowd. About 0.8 GB of it is never written and only became
  resident through jemalloc recycling recently freed pages (`FSHeapDecayMs` fixes that). The rest
  costs real memory; shrink it with fewer buffer creations, or `glBufferStorage`.
- **Who writes upload data** (`FSVBOAllocTrace` call stacks, ~75 avatars):
  - avatar system body meshes (`LLVOAvatar::updateMeshData`, from the shadow pass): ~9–10 GB/min of
    rewrites of existing buffers in the first minutes after arrival, fading after about 10 minutes
  - object rebuilds (`rebuildGeom` → `genDrawInfo` → `getGeometryVolume`): 3–5 GB/min, always into
    new buffers; this is the create/delete churn behind the driver reservations
  - particles: about 0.6 GB/min
- **Which objects rebuild** (`RebuildTrace`): about 90% is other avatars' attachments, because one
  busy prim costs its whole attachment. Where the fixes live:
  - flexi prims crossing octree nodes: `FSOctreeBridgeMoveSlack`, `LLSpatialGroup::updateInGroup`.
    Culling is unaffected because group bounds come from the objects (`LLViewerOctreeGroup::rebound`),
    not the node box.
  - colour changes: `LLVOVolume::setTEColor`; faces stay in place when their alpha class
    (`LLFace::fsAlphaClass`: invisible, blended, nearly opaque, opaque) doesn't change.
  - scripted hide/show: a hidden face keeps its batch with degenerate indices
    (`LLFace::getGeometryVolume`) and is shown in place when its batched class
    (`mFSBatchedAlphaClass`) matches. A group rebuild within 10 s of a hide keeps it in its pre-hide
    pool (`LLFace::fsKeepHiddenInBatch`). Debug views that draw invisible faces (show transparent,
    highlights with scripted beacons) fall back to full rebuilds (`LLFace::fsCanHideInPlace`).
- **Measuring:** with `FSVBOAllocTrace`, each minute's log has jemalloc's live/active/dirty totals
  next to the process's anon RSS and swap. Active minus anon+swap is heap that isn't really in memory.

## Testing

Build, install and the "never run from `packaged/`" rule are in `AGENTS.md` ("Building (Linux)").
The process is named `do-not-directly-run-companionviewer-bin`; the user-data folder is
`~/.companionviewer`, overridden with `COMPANIONVIEWER_USER_DIR`. To tell one instance from another,
check that variable in `/proc/<pid>/environ`, not the newest process.

**Working rules** (each came from something that went wrong):
- Ask before launching any viewer, and before closing one: memory measurements are only comparable
  when nothing else heavy is running.
- Never touch the user's normal install or its user-data folder. Test builds get their own install
  folder and user-data folder.
- Never edit a launcher or wrapper script in place while a viewer started from it is running. bash
  reads scripts incrementally; an in-place edit once re-ran the launch line and started a phantom
  extra instance. Write a temporary file and rename it over the original.
- A move or delete of cache or user-data folders must hard-abort if a viewer is running (for example
  `if pgrep -f do-not-directly-run-companionviewer-bin >/dev/null; then exit 1; fi` under `set -e`,
  not chained with `;`). Swapping a cache under a live viewer once produced garbage textures and a
  corrupted texture cache.
- A second instance deletes its own log on a clean exit (`logs/dump_logs/<uuid>.log`). Copy it
  before closing that instance if you need it.
- After copying the packaged tree, `bin/dullahan_host`, `bin/chrome-sandbox` and `bin/SLVoice` must
  be mode 755. At 644 the web login page, profiles, media and voice silently break.

**Unattended runs** (only with the owner's go-ahead): log in with `--autologin` and
`--set QuitAfterSeconds 780`, which logs out properly after 13 minutes of rendering (`SIGTERM` exits
gracefully but sends no logout to the sim). Wait about 90 s between runs, and copy the log after each
run because the next launch replaces it. For baseline-vs-change comparisons, restore the same
starting cache before each run, use the same region and duration, and note crowd size and settings.

**Measurement tools:**
- Per-process RSS and swap: `/proc/<pid>/smaps_rollup`, sampled every 30 s.
- GPU memory: `nvidia-smi`. Memory pressure: `/proc/pressure/memory`.
- Where the heap goes: jemalloc heap profiles (`FS_JEMALLOC_LIB` pointing at a profiling build,
  `MALLOC_CONF` for snapshots), read with
  `jeprof --text --show_bytes [--cum --focus=<fn>] <binary> <snapshot>`. Heap profiles count
  allocated bytes, not resident pages, so always cross-check against RSS.
- NVIDIA's threaded optimisation makes the driver allocate on its own threads, which hides callers.
  The wrapper turned it on before the 7.3 rebase (the measurements here were taken that way); it is
  now off unless set, so `__GL_THREADED_OPTIMIZATIONS=0` is only needed for older builds.
- Standalone GL experiments (a small C program with a headless EGL or GLX context, plus
  `/proc/self/status` and jemalloc's `thread.allocatedp`/`thread.deallocatedp`) are much faster than
  viewer runs for driver questions.

**Reading `RebuildTrace`:** each minute logs rebuilt bytes by kind of object and what the groups
hold, octree moves and their reasons, colour changes by alpha class (and how many were in place),
the 20 groups that rebuilt most, and the call stacks that queued group and drawable rebuilds. Stacks
are module offsets: `addr2line -f -C -e <installed bin/do-not-directly-run-companionviewer-bin>
<offset - 1>` gives function names quickly; the build tree's unstripped
`build-linux-x86_64/newview/companionviewer-bin` (same build ID) also gives `-i` file:line but takes
minutes per lookup. A group queued from `LLVOVolume::updateGeometry` only passes on a drawable
request; the drawable stacks show the real cause.

**Visual check for colour/alpha changes:** a box with this script, on the ground and worn. Each step
says in local chat what should be visible. Compare with `FSInPlaceColorUpdates` off.
```lsl
list STEPS = ["opaque red", <1,0,0>, 1.0, "HIDDEN", <1,0,0>, 0.0, "opaque red again", <1,0,0>, 1.0,
    "HIDDEN", <1,0,0>, 0.0, "opaque GREEN", <0,1,0>, 1.0, "half see-through blue", <0,0,1>, 0.5,
    "HIDDEN", <0,0,1>, 0.0, "half see-through blue again", <0,0,1>, 0.5,
    "HIDDEN (turning yellow unseen)", <1,1,0>, 0.0, "opaque YELLOW", <1,1,0>, 1.0];
integer step;
default
{
    state_entry() { step = 0; llSetTimerEvent(2.0); }
    attach(key id) { step = 0; }
    timer()
    {
        llSetLinkPrimitiveParamsFast(LINK_SET, [PRIM_COLOR, ALL_SIDES,
            llList2Vector(STEPS, step * 3 + 1), llList2Float(STEPS, step * 3 + 2)]);
        llOwnerSay((string)(step + 1) + ": " + llList2String(STEPS, step * 3));
        step = (step + 1) % (llGetListLength(STEPS) / 3);
    }
}
```

**Visual check for a show after a group rebuild:** a face hidden in place, a rebuild of its group
while it is hidden (forced here by making another face half see-through), then the hidden face shown
again. Before the fix the shown face stayed a hole (first seen as holes in a card-game HUD). Use a
plain cube; face 0 is the top and face 1 a side.
```lsl
list STEPS = ["all opaque red", 1.0, 1.0, "top HIDDEN", 0.0, 1.0,
    "side half see-through (forces a rebuild), top still hidden", 0.0, 0.5,
    "top shown again: red top should be VISIBLE", 1.0, 0.5, "side opaque again", 1.0, 1.0];
integer step;
default
{
    state_entry() { step = 0; llSetTimerEvent(3.0); }
    timer()
    {
        llSetLinkPrimitiveParamsFast(LINK_THIS, [PRIM_COLOR, ALL_SIDES, <1,0,0>, 1.0,
            PRIM_COLOR, 0, <1,0,0>, llList2Float(STEPS, step * 3 + 1),
            PRIM_COLOR, 1, <1,0,0>, llList2Float(STEPS, step * 3 + 2)]);
        llOwnerSay((string)(step + 1) + ": " + llList2String(STEPS, step * 3));
        step = (step + 1) % (llGetListLength(STEPS) / 3);
    }
}
```

## macOS: what to expect

Nothing from this work has been run on macOS yet.

| Change | macOS status |
|---|---|
| Texture-cache fixes, atomic disk-cache writes, instance slots (APR file locks), settings-on-exit | Portable; should work as on Linux |
| Linux memory pressure, thread naming, jemalloc tracing | `LL_LINUX` only |
| Freeing VBO CPU copies, GPU-copy uploads | Skipped on Apple GPUs (`mIsApple`). **Active on Intel Macs with AMD or Intel GPUs** (GL 4.1); both use GL 3.1 calls but are untested there |
| `FSHeapDecayMs`, `FSVBOAllocTrace` | Linux with jemalloc only; no-ops on macOS. `RebuildTrace` counts work everywhere, call stacks are Linux only |
| `FSOctreeBridgeMoveSlack`, `FSInPlaceColorUpdates`, bake-mask skip | Portable |

- macOS won't start a second instance of the same application. Workarounds: two copies of the app
  bundle under different names, or `open -n -a <app>` (untested). Both would share the same
  user-data and cache folders, which the cache sub-folders per instance keep safe. Session-only
  `--set` overrides would be passed as `open -n -a <app> --args ...`.
- Memory tools: `footprint`, `vmmap --summary`, `heap`, `leaks`, and Instruments (Allocations, VM
  Tracker); `MallocStackLogging=1` gives allocation call stacks. On Apple Silicon, GL runs on a
  translation layer over Metal, so the NVIDIA findings above don't carry over.

## Other ideas (not scheduled)

- **"Fix Moblins":** a World/Advanced menu command that finds avatars with zero attachment objects
  (after a grace period, ignoring impostors and jelly dolls) and re-requests only their attachments.
  Never automatic. Starting points: `LLViewerRegion::addCacheMiss`/`requestCacheMisses`
  (`RequestMultipleObjects`), the orphan handling in `LLViewerObjectList`, and what changing draw
  distance triggers.
- **Pie menu layout:** move common actions such as "Render Fully" up from the fourth level.
