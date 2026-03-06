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
