# Rebase Plan

## Goal

Turn the fork from "one giant feature commit plus drift" into "small patch stack on top of `upstream/main`".

That is the difference between:

- rebasing by hand across 40+ files every time Ghostty moves
- letting an agent fix one concern at a time

## Current State

As of March 5, 2026:

- `main` mirrors `upstream/main`
- `glossolalia` sits on one monolith feature commit:
  - `9cd09ec7e feat(glossolalia): add audio-reactive rendering, media pipeline, and MIDI controls`
- fork scaffolding now lives in a separate follow-up commit:
  - branding seam
  - release scaffolding
  - rebase docs/tooling

The monolith commit touches 46 files. That is the real rebase problem.

## Target Stack

Rebuild the fork into this order:

1. `chore(fork): add branding seam and release scaffolding`
2. `feat(glossolalia): add config and protocol hooks`
3. `feat(glossolalia): add renderer plumbing and shaders`
4. `feat(glossolalia): add audio engine`
5. `feat(glossolalia): add video engine`
6. `feat(glossolalia): add macOS integration`
7. `feat(glossolalia): add GTK integration`
8. `docs(glossolalia): document media dependencies and usage`

Keep the stack in this shape. Do not re-squash it later.

## File Buckets

### 1. Fork Scaffolding

Already separated by the current staged work:

- `AGENTS.md`
- `FORKING.md`
- `REBASE_PLAN.md`
- `scripts/fork-sync.sh`
- `.github/workflows/fork-rebase-check.yml`
- `.github/workflows/release-fork-macos.yml`
- `dist/macos/update_appcast_fork.py`
- `macos/GlossolaliaBrand.xcconfig`
- `macos/Ghostty-Info.plist`
- `macos/Sources/Helpers/ProductBrand.swift`
- fork-owned macOS branding call sites

### 2. Config And Protocol Hooks

Keep this patch small and mechanical:

- `build.zig.zon`
- `include/ghostty.h`
- `src/build/SharedDeps.zig`
- `src/config.zig`
- `src/config/Config.zig`
- `src/input/Binding.zig`
- `src/input/command.zig`
- `src/terminal/osc.zig`
- `src/terminal/osc/parsers/iterm2.zig`
- `src/terminal/stream.zig`
- `src/terminal/stream_readonly.zig`
- `src/termio/stream_handler.zig`

Rule: no renderer logic here. No app-specific UI here.

### 3. Renderer Plumbing And Shaders

This is the hottest upstream zone. Keep it isolated:

- `src/Surface.zig`
- `src/renderer/Thread.zig`
- `src/renderer/generic.zig`
- `src/renderer/glossolalia.zig`
- `src/renderer/image.zig`
- `src/renderer/message.zig`
- `src/renderer/metal/shaders.zig`
- `src/renderer/opengl/shaders.zig`
- `src/renderer/shaders/glossolalia_equalizer_glyph.glsl`
- `src/renderer/shaders/glsl/cell_text_mask.f.glsl`
- `src/renderer/shaders/shaders.metal`
- `src/renderer/shaders/shadertoy_prefix.glsl`
- `src/renderer/shadertoy.zig`

Rule: push new behavior into `src/renderer/glossolalia.zig` first. Keep `generic.zig` as hook glue.

### 4. Audio Engine

Keep audio logic out of renderer patches:

- `src/audio/Glossolalia.zig`
- `src/audio/miniaudio.c`

If possible, reduce any audio-related edits elsewhere to narrow hooks only.

### 5. Video Engine

Keep video state and playback separate from app glue:

- `src/video/BackgroundVideo.zig`
- `src/apprt/embedded.zig`
- `src/apprt/none.zig`
- `src/apprt/surface.zig`

If `src/Surface.zig` ends up needed here as well, keep it in the renderer patch and call into video from there.

### 6. macOS Integration

This patch is allowed to be platform-specific and ugly. Keep it out of core:

- `macos/Sources/App/macOS/AppDelegate.swift`
- `macos/Sources/App/macOS/BackgroundMediaNowPlayingController.swift`
- `macos/Sources/Ghostty/Ghostty.App.swift`
- `macos/Sources/Ghostty/Ghostty.Config.swift`
- `macos/Sources/Ghostty/Midi/GlossaliaMIDI.swift`
- `macos/Sources/Ghostty/Midi/MIDIKeyMap.swift`
- `macos/Sources/Ghostty/Midi/MIDIScale.swift`
- `macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift`
- `macos/Sources/Ghostty/Surface View/SurfaceView_UIKit.swift`

Rule: do not let macOS naming leak back into Zig core APIs unless unavoidable.

### 7. GTK Integration

Keep Linux/GTK surface separate so macOS release work can move independently:

- `src/apprt/gtk/Surface.zig`
- `src/apprt/gtk/build/gresource.zig`
- `src/apprt/gtk/class/surface.zig`
- `src/apprt/gtk/class/surface_background_video_dialog.zig`
- `src/apprt/gtk/ui/1.5/surface-background-video-dialog.blp`

### 8. Docs And Usage

Keep user-facing docs last:

- `README.md`

## Migration Procedure

Run this once when ready to rewrite the branch:

1. Create a safety branch.
2. Soft-reset `glossolalia` to `upstream/main`.
3. Re-commit files bucket by bucket in the order above.
4. Build after each commit that touches a runtime path.
5. Rebase the new stack onto fresh `upstream/main` before pushing.

Suggested command sequence:

```sh
git branch backup/glossolalia-monolith
git reset --soft upstream/main
git restore --staged .

# commit 1 already exists if the fork scaffolding commit is on the branch

# then rebuild the stack:
git add <config/protocol files...>
git commit -m "feat(glossolalia): add config and protocol hooks"

git add <renderer files...>
git commit -m "feat(glossolalia): add renderer plumbing and shaders"

git add <audio files...>
git commit -m "feat(glossolalia): add audio engine"

git add <video files...>
git commit -m "feat(glossolalia): add video engine"

git add <macOS files...>
git commit -m "feat(glossolalia): add macOS integration"

git add <gtk files...>
git commit -m "feat(glossolalia): add GTK integration"

git add README.md
git commit -m "docs(glossolalia): document media dependencies and usage"
```

## Rebase Rules After Migration

When Ghostty moves:

1. Rebase `glossolalia` onto fresh `upstream/main`.
2. Fix conflicts one commit at a time.
3. If one commit conflicts in more than one concern, stop and split it smaller.
4. Re-run the same build/test slices after each repaired commit.
5. Let `git rerere` learn the repeated fixes.

Local setup:

```sh
git config rerere.enabled true
git config rebase.autoStash true
```

## Verification Matrix

Run the smallest useful verification per patch:

- fork scaffolding: `git diff --check`
- config/core patches: `zig build test`
- macOS patches: `xcodebuild -project macos/Ghostty.xcodeproj -target Ghostty -configuration Debug CODE_SIGNING_ALLOWED=NO ARCHS=arm64 ONLY_ACTIVE_ARCH=YES build`
- release plumbing: `python3 -m py_compile dist/macos/update_appcast_fork.py`

Do not wait until the end of the stack to discover breakage.

## Non-Goals

Do not do these during the rebase cleanup:

- mass-rename internal `Ghostty` symbols
- move directories around for aesthetics
- build a second wrapper app around `libghostty`
- unify macOS and GTK patches if they can stay separate

That work increases conflict surface without helping the fork stay current.
