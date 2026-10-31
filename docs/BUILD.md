# Building and installing the IPA

## How the IPA is produced

Everything happens on GitHub's macOS runners — no Mac needed.

| Workflow | Trigger | Output |
|---|---|---|
| `ci.yml` | every push / PR | backend tests, Swift core tests, simulator UI test, **unsigned IPA artifact** `WorldTreeAI-unsigned-ipa` |
| `release.yml` | push a tag `v1.0.0` (or run manually) | GitHub release **"WORLD TREE AI v1.0.0 — Famous Family Multiverse"** with the unsigned IPA, a signed IPA if you added signing secrets, and `SHA256SUMS.txt` |
| `security.yml` | push / weekly | CodeQL (Python), secret scan, dependency policy |

Build steps (reproducible): `xcodegen generate` → `xcodebuild archive -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO`
→ `scripts/package-ipa.sh` zips `Payload/WorldTreeAI.app`. The runner image and Xcode version are printed in each log.

### Exact artifact locations

- **CI build:** GitHub → your repo → **Actions** → latest **CI** run → *Artifacts* → `WorldTreeAI-unsigned-ipa` (a zip containing `WorldTreeAI-unsigned.ipa`).
- **Release:** GitHub → your repo → **Releases** → *WORLD TREE AI v1.0.0 — Famous Family Multiverse* → `WorldTreeAI-1.0.0-unsigned.ipa`.

To cut the release: create a tag `v1.0.0` (GitHub → Releases → *Draft a new release* → choose tag `v1.0.0` → publish),
or Actions → **Release** → *Run workflow* with version `1.0.0`.

## Installing with Signulous

The IPA is **unsigned**. Signulous signs uploaded IPAs with the certificate tied to your Signulous
device registration, which is why an unsigned build is the right input.

1. Download `WorldTreeAI-…-unsigned.ipa` to your iPhone (Files app).
2. In Signulous, use its option to upload/sign your own IPA and pick that file.
3. Install when Signulous finishes signing. Bundle ID: `ai.worldtree.app`.

If Signulous rejects it, check that your device is registered with them and that the IPA downloaded completely
(compare against `SHA256SUMS.txt` on the release).

## Optional: signing in CI with your own Apple account

Add these repository secrets and the release workflow also produces `…-signed.ipa` (ad-hoc):

| Secret | Value |
|---|---|
| `IOS_P12_BASE64` | base64 of your distribution certificate `.p12` |
| `IOS_P12_PASSWORD` | its password |
| `IOS_PROVISIONING_PROFILE_BASE64` | base64 of an ad-hoc profile for `ai.worldtree.app` that includes your device |
| `IOS_TEAM_ID` | your Apple Developer Team ID |

Without these secrets the signed step is skipped — the workflow never pretends a signed IPA exists.
