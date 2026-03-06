# Forking Glossolalia

Glossolalia should behave like an overlay on top of Ghostty, not a sibling codebase.

## Product Surface

Keep product identity declarative:

- macOS app metadata and updater endpoints live in `macos/Ghostty-Info.plist`
- Xcode build-time identity defaults live in `macos/GlossolaliaBrand.xcconfig`
- macOS runtime branding reads from `macos/Sources/Helpers/ProductBrand.swift`
- app icons live under `macos/Assets.xcassets`
- release/update automation should read from one fork-owned workflow, not Ghostty’s hosted infra assumptions

The intended cutover is:

1. keep local defaults safe in `macos/GlossolaliaBrand.xcconfig`
2. override shipping identity in `.github/workflows/release-fork-macos.yml`
3. when the brand is final, move those release overrides back into the xcconfig

## Branch Shape

Keep three lanes:

- `main`: clean mirror of `upstream/main`
- `glossolalia`: ship branch
- topic branches: one concern per branch, rebased onto `glossolalia`

Do not collapse the fork into one giant squash commit again. Keep a patch stack:

1. brand/release surface
2. config/API hooks
3. renderer hooks
4. audio engine
5. video engine
6. macOS glue
7. GTK glue

This makes conflict repair local and agent-friendly.

For the concrete migration from the current monolith commit to that stack,
see `REBASE_PLAN.md`.

## Daily Workflow

This structure is meant to keep change easy, not bureaucratic.

Normal feature flow:

1. branch from `glossolalia`
2. make the change on a topic branch
3. keep commits scoped by concern
4. land the topic branch back onto `glossolalia`
5. delete the topic branch when done

Suggested branch names:

- human work: `feature/<name>` or `fix/<name>`
- agent work: `codex/<name>`

Rules:

- `glossolalia` is not a scratchpad. Keep experiments and half-finished ideas on topic branches.
- Messy WIP is allowed on topic branches. Clean history only before landing.
- Small hotfix directly on `glossolalia` is acceptable only if it is truly one concern, low risk, and faster than making a topic branch.
- If a feature grows across config, renderer, platform glue, and release logic, split it before landing.
- If only one platform is shipping, avoid touching the other platform unless the API shape requires it.
- Default landing path is topic branch -> clean commits -> `glossolalia`.
- Default salvage path for messy work is cherry-pick the good commits, not merge the whole branch.

Landing options:

- rebase the topic branch onto `glossolalia`, then fast-forward `glossolalia`
- or cherry-pick clean commits from the topic branch onto `glossolalia`

Prefer cherry-pick when the topic branch contains messy exploration you do not want in ship history.

## Non-Negotiables

- Do not use `glossolalia` as a long-running personal work branch.
- Do not force unrelated work into one commit to "keep history small".
- Do not let branch cleanup wait until the next upstream rebase.
- Do not widen edits in upstream churn zones when a hook or helper file would do.
- Do not postpone rebases until conflict context is cold.

## Rebase Loop

Use `scripts/fork-sync.sh` for local rebases:

```sh
./scripts/fork-sync.sh
```

That script:

- refuses a dirty worktree
- fetches `upstream/main`
- rebases `glossolalia` onto it

Use `.github/workflows/fork-rebase-check.yml` to catch breakage on a schedule.

Recommended local git config:

```sh
git config rerere.enabled true
git config rebase.autoStash true
```

Human rule:

- keep making whatever changes you want on topic branches
- only make `glossolalia` pay the rebase cost for finished, scoped work

Practical cadence:

- rebase `glossolalia` after meaningful upstream Ghostty movement
- if actively building, do not let `glossolalia` drift for more than about a week
- if a topic branch lives too long, rebase it or cherry-pick the good commits out

## Release Cutover

Fork-owned macOS release automation lives in `.github/workflows/release-fork-macos.yml`.

Required secrets:

- `MACOS_CERTIFICATE`
- `MACOS_CERTIFICATE_PWD`
- `MACOS_CERTIFICATE_NAME`
- `MACOS_CI_KEYCHAIN_PWD`
- `APPLE_NOTARIZATION_ISSUER`
- `APPLE_NOTARIZATION_KEY_ID`
- `APPLE_NOTARIZATION_KEY`
- `SPARKLE_PUBLIC_ED_KEY`
- `SPARKLE_PRIVATE_ED_KEY`

Before first public release:

- replace the placeholder app icon asset name if you want a non-Ghostty icon
- choose the final release bundle ID and product name in the workflow env
- enable GitHub Pages so the generated `appcast.xml` has a stable URL

## Agent Rules

- Prefer new files over edits in upstream churn zones.
- If a feature touches `renderer/generic.zig`, `Config.zig`, app delegates, or release workflows, isolate the seam first.
- Rebrand through metadata/helpers, not scattered string replacement.
- If a rebase conflict crosses more than one concern, split the patch before continuing.
