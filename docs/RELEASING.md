# GitHub tag releases

Pushing a version tag runs `.github/workflows/release.yml`. It builds on native
Linux and Windows runners, builds a signed universal Android APK, runs checks,
and publishes a GitHub Release only after all three builds pass. The release
starts as a draft, receives all verified assets, then becomes public. A failed
upload leaves a draft that the publish job can resume on a rerun. An already
published release is never overwritten; use a new version tag for another release.

The branch/PR workflow remains separate and does not duplicate tag builds.
Deleting a tag does not create a release. iOS is outside this release workflow.

## One-time Android signing setup

Use a persistent keystore that you back up outside the repository. GitHub-hosted
runners are fresh machines, so their generated debug keys cannot provide stable
APK upgrades. The release job intentionally fails if signing secrets are missing.
Local development builds still use the existing local debug key when no signing
environment variables are configured.

If you already have an Android signing key, keep using it. To create a new one:

```sh
keytool -genkeypair -v -storetype JKS -keystore "$HOME/narad-release.jks" \
  -alias narad -keyalg RSA -keysize 3072 -validity 10000
```

Under **GitHub repository → Settings → Secrets and variables → Actions**, create:

| Repository secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | Base64 encoding of the keystore file, on one line |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_ALIAS` | Signing alias, for example `narad` |
| `ANDROID_KEY_PASSWORD` | Password for that key/alias |

With GitHub CLI authenticated in the repository, this Linux command uploads the
encoded keystore directly, without printing it or committing it:

```sh
base64 -w0 "$HOME/narad-release.jks" | gh secret set ANDROID_KEYSTORE_BASE64
gh secret set ANDROID_KEYSTORE_PASSWORD
gh secret set ANDROID_KEY_ALIAS
gh secret set ANDROID_KEY_PASSWORD
```

The last three commands prompt for their values. No personal access token is
needed by the workflow: only its publish job gets `contents: write` through the
automatic `GITHUB_TOKEN`. Repository/organization policy must allow Actions and
that permission. Signing material is restored under the runner's temporary
directory, is not uploaded as an artifact, and is removed after the Android build.

Android requires the same signing certificate for upgrades. Existing Narad builds
use the developer machine's debug keystore; a new production key cannot update
those installations in place. If you need to preserve that upgrade path, use the
same existing keystore in CI instead of generating a different one. Keep its
password/alias settings consistent. Windows packages are not Authenticode-signed.

## Publish a version

1. Commit the workflow and configure the signing secrets above.
2. Update `clients/flutter/pubspec.yaml`, for example `version: 0.2.0+13`.
   The name must match the tag without its optional `v` prefix. Increment the
   numeric build number for every Android release; it becomes `versionCode`.
3. Commit that version change, push the commit, then push its tag:

```sh
git add clients/flutter/pubspec.yaml
git commit -m "release: prepare 0.2.0"
git push origin HEAD
git tag -a v0.2.0 -m "Narad 0.2.0"
git push origin v0.2.0
```

Tags such as `v0.2.0-beta.1` are published as prereleases and require a matching
app version such as `0.2.0-beta.1+14`. Non-version tags and mismatched app versions
fail validation before builds start. Do not move a published release tag.

The release contains these files and one `.sha256` file for each:

- `narad-windows-x64-release.zip`: app, bundled daemon and install scripts.
- `narad-linux-x64-release.run`: Linux per-user installer.
- `narad-linux-x64-release.tar.gz`: portable Linux bundle.
- `narad-android-release.apk`: signed universal ARM64, ARMv7 and x86_64 APK.

Build artifacts are also retained in the Actions run, including when a different
platform fails. APK signature, 16 KiB alignment and all downloaded checksums are
verified before publication. Check the **Actions → Build and publish release**
run for failures; after correcting secrets, rerun failed jobs without moving the
tag. This workflow has been checked locally; its first hosted run will validate
the GitHub runner/toolchain setup and your repository signing configuration.

For local signing outside Actions, set all four `NARAD_ANDROID_KEYSTORE`,
`NARAD_ANDROID_STORE_PASSWORD`, `NARAD_ANDROID_KEY_ALIAS` and
`NARAD_ANDROID_KEY_PASSWORD` environment variables before building. Partial
configuration fails rather than silently falling back to a debug signature.
