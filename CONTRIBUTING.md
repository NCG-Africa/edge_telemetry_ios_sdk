# Contributing to EdgeRum

Thanks for helping build the EdgeRum iOS SDK. This guide covers the two
things that keep the release pipeline honest: **commit message format**
and **how a change ships**. For architecture and the terminology
firewall, read `CLAUDE.md`; for the "why" behind these choices, see
`docs/decisions.md` (ADR-015 in particular).

## Branch & PR flow

1. Branch off `main`.
2. Make your change; keep the diff focused.
3. Open a PR into `main`. CI (`ci.yml`) must be green — build, tests,
   the terminology firewall, `pod lib lint`, docs, and the sample apps.
4. Squash-merge. **The squash commit message must follow Conventional
   Commits** (below), because release automation reads it.

## Conventional Commits — required

Releases are automated by [release-please](https://github.com/googleapis/release-please),
which decides the next version and writes `CHANGELOG.md` **entirely from
commit messages** on `main`. A commit that doesn't follow the format is
silently ignored for the changelog — so mislabelled work never surfaces
in release notes and can't bump the version.

Format:

```
<type>(<optional scope>): <summary>

<optional body>

<optional footer>
```

### Types

| Type        | Use for                                        | Version bump | In changelog? |
|-------------|------------------------------------------------|--------------|---------------|
| `feat`      | A new capability on the public SDK surface     | **minor**    | yes           |
| `fix`       | A bug fix in shipped behaviour                 | **patch**    | yes           |
| `docs`      | Docs only (README, DocC, this file, ADRs)      | none         | no            |
| `test`      | Tests only                                     | none         | no            |
| `refactor`  | Internal change, no behaviour change           | none         | no            |
| `perf`      | Performance improvement                        | patch        | yes           |
| `build`     | Build system, packaging, dependencies          | none         | no            |
| `ci`        | CI / release workflows                         | none         | no            |
| `chore`     | Everything else (tooling, samples, housekeeping)| none         | no           |

### Breaking changes → major bump

Two ways to mark one (either triggers a **major** version bump):

- Add `!` after the type/scope: `feat!: rename EdgeRum.track to record`
- Add a `BREAKING CHANGE:` footer:

  ```
  feat: replace captureError signature

  BREAKING CHANGE: captureError now takes [String: AttributeValue]
  instead of [String: Any]. Callers must migrate their context maps.
  ```

Pre-1.0 note: while the version stays `0.x` / `1.0.0-alpha.x`, treat the
public API as still-settling, but keep marking breaks honestly — the
markers are what the changelog and downstream migration notes rely on.

### Examples

```
feat(swiftui): add edgeRumTrackTap view modifier
fix(transport): honour Retry-After cap of 60s on 429
docs: document the API-key onboarding path
ci: publish the pod to CocoaPods trunk on tagged releases
feat!: drop iOS 13 support
```

## How a release ships

You don't tag or edit `VERSION` by hand — release-please does it:

1. Commits land on `main` (via squash-merged PRs).
2. release-please opens/updates a **"chore: release X.Y.Z"** PR that
   bumps `version.txt` (the repo-root `VERSION` symlinks to it) and
   updates `CHANGELOG.md`.
3. Merging that PR pushes a `vX.Y.Z` tag and creates the GitHub Release.
4. The tag fires `release.yml`, which builds + attaches the XCFramework
   and pushes the CocoaPods trunk spec. SwiftPM consumers get the new
   version the moment the tag exists.

To force a specific version (e.g. graduate to `1.0.0`), add a
`Release-As: 1.0.0` line to a commit body on `main`.

## Terminology firewall

Anything public-facing (the `EdgeRum` module's symbols, their doc
comments, the README, CHANGELOG, sample strings) must avoid the banned
vocabulary in `CLAUDE.md` §"Rule 1". `Tools/firewall-check.sh` enforces
this in CI — run it locally before pushing if you touched public API or
docs.
