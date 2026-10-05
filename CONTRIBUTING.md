# Contributing to EdgeRum

Thanks for helping build the EdgeRum iOS SDK. This guide covers the two
things that keep the release pipeline honest: **commit message format**
and **how a change ships**. For architecture and the terminology
firewall, read `CLAUDE.md`; for the "why" behind these choices, see
`docs/decisions.md` (ADR-018 in particular).

## Branch & PR flow

1. Branch off `main`.
2. Make your change; keep the diff focused.
3. Open a PR into `main`. CI (`ci.yml`) must be green — build, tests,
   the terminology firewall, `pod lib lint`, docs, and the sample apps.
4. Squash-merge. **The squash commit message must follow Conventional
   Commits** (below), because release automation reads it.

## Conventional Commits — required

Commit messages on `main` are the raw material for `CHANGELOG.md` and
the version bump at release time, so keep them in this format.

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

Releases are cut by hand:

1. On a branch, bump `version.txt` (the repo-root `VERSION` symlinks to
   it) and add the `CHANGELOG.md` section from the commits since the
   last tag. Merge via PR.
2. Tag the merged commit `vX.Y.Z` (must equal `VERSION`) and push the tag.
3. The tag fires `release.yml`, which builds + attaches the XCFramework,
   creates the GitHub Release, and pushes the CocoaPods trunk spec.
   SwiftPM consumers get the new version the moment the tag exists.

## Terminology firewall

Anything public-facing (the `EdgeRum` module's symbols, their doc
comments, the README, CHANGELOG, sample strings) must avoid the banned
vocabulary in `CLAUDE.md` §"Rule 1". `Tools/firewall-check.sh` enforces
this in CI — run it locally before pushing if you touched public API or
docs.
