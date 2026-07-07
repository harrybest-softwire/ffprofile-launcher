# ffprofile

A macOS command-line tool (Swift, single `main.swift`) for managing and launching Firefox profiles: fuzzy profile matching, window focusing via Accessibility, per-profile Spotlight apps, and a default-browser profile picker for opening links in a specific profile.

## Build and test

```sh
make          # builds ./ffprofile (swiftc, no package manager)
```

There is no test suite. Verify changes by running the binary directly, e.g. `./ffprofile list`, or `./ffprofile launch <profile> --url <url>`. Invalid-URL cases exit before launching anything, so they're safe to test against a real profile.

Installed artifacts live outside the repo: `~/Applications/ffprofile.app` (shared helper the apps and link clicks route through) and `~/Applications/<profile> - Firefox.app`. Link clicks go to the installed helper, not the repo binary, so launch-behaviour changes aren't live until shipped. The binary on this machine is Homebrew-managed — never run `./ffprofile install` or `make install` from a repo build. To ship: cut a release (below), then `brew upgrade ffprofile` — the formula's post_install refreshes the installed apps. Replacing the helper binary can invalidate its Accessibility grant.

## Commits

- Commit as Claude: every commit gets a `Co-Authored-By: Claude <model> <noreply@anthropic.com>` trailer, where `<model>` names the model that wrote the change (e.g. `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`).
- Subject line only, no description body (the co-author trailer is the one exception).
- Imperative, sentence-case subjects with no conventional-commit prefix, matching `git log`.

## Releases

Users install through the Homebrew formula in `Formula/ffprofile.rb` (this repo is the tap), which points at a tagged tarball. To release: `git tag vX.Y.Z && git push origin vX.Y.Z` — the bump-formula workflow then updates the formula's url/sha256 with a commit to main. Never edit those two lines by hand; pull after the workflow runs.

## Gotchas

- Link text piped to `launch` can be a hyperlink's display text, not the href (Slack does this). `normalizeURL` in main.swift rejects non-URL text; don't reintroduce guessing.
- Apple Events to Firefox need per-sender Automation consent and can stall; window focusing and Cmd+N go through Accessibility instead. Keep new window/focus logic on that path.
- The helper must never replace its own binary while running as the helper (see `installHelperApp`).
