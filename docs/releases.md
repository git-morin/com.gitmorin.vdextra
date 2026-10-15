# Releases and updates

Two channels, both published from CI:

| Channel | Published by | Tag | Marked |
| --- | --- | --- | --- |
| **Stable** | a push to `main` | `v1.2.0` | latest release |
| **Dev** | a push to `dev` | `v1.2.0-dev.57` | prerelease |

Only the newest dev prerelease is kept; superseded ones are deleted along with their tags, so
the channel is always current without the release list growing without bound.

A manual workflow dispatch builds and uploads an artifact but publishes nothing, which is what
the local `make ship` loop wants.

## Versioning

The version is computed from git history, never from a value committed in the tree — a job that
commits a bump to `main` would only retrigger itself. The next version comes from the highest
stable tag plus the [Conventional Commits](https://www.conventionalcommits.org) in the range
since it:

- a `!` marker or a `BREAKING CHANGE:` footer → major
- any `feat:` → minor
- anything else → patch

The breaking footer is matched at the start of a line with its colon, per the spec. Matching the
bare phrase anywhere means a commit message *describing* this rule trips it, which is exactly
what happened once.

`versionCode` is packed as `major*1e6 + minor*1e4 + patch*100 + serial`, where a stable build
takes serial `99` and a dev build its commit count. So every dev build of a version sorts below
its stable release — stable always installs over dev — and the whole sequence stays monotonic,
which is what lets Android treat each build as an upgrade of the last.

## The updater needs public releases

The app reads the GitHub releases API anonymously, so the repository has to be public for any
of it to work. The releases endpoint answers **404**, not 403, for a repository the caller
cannot see, so against a private repo the check reports "releases are not public (HTTP 404)"
and the launch-triggered check logs the same under the `VDExtra` tag.

Shipping a token inside the APK is not an option - anyone can unzip it - so if the source has
to stay private the alternative is publishing a manifest and the APK to a separate public
location and pointing the app at that.

## Updating from inside the app

**Options → Updates** carries the channel picker and a check row. The first tap checks the
selected channel; once something newer is found, the same row downloads and installs it.

Virtual Desktop launching also triggers a check, throttled to once every six hours, and posts a
notification if an update is waiting. The module broadcasts to VDExtra rather than checking in
place: the work would otherwise run under Virtual Desktop's identity, so the notification would
appear to come from Virtual Desktop and would need Virtual Desktop to hold the notification
permission.

Comparison is semver precedence on the version string, deliberately not a second copy of the
`versionCode` arithmetic above — that formula would then live in two places and could silently
disagree. `1.2.0` outranks `1.2.0-dev.57`, which outranks `1.1.0`, so a stable release also
reaches dev-channel users once it overtakes the last prerelease.

Installing hands the APK to `PackageInstaller`, so the system shows its own install prompt.
VDExtra needs permission to install apps for that to work; if it does not have it, the check row
says so and opens the right settings screen. After updating, force-stop and restart Virtual
Desktop so the new native code is loaded.
