# Desktop notification sync verification

Verified on 2026-10-21 from commits `aca9b77` and `8a0a51a`.

## Automated checks

- Flutter analysis: no issues; 17 focused notification/bridge tests passed.
- Rust library tests: 34 passed; Clippy passed with warnings denied.
- Linux native capture suite: opt-in, real server notification IDs, replacement,
  plain-text body, icons, mirror-loop exclusion, dismissal, service restart, opt-out.
- Linux installer suite: all seven installation, upgrade, integrity and backend
  lifecycle checks passed on the refreshed installer.
- Workflow YAML and MSIX manifest XML parsed successfully.
- Linux debug and Android debug builds completed. The universal APK contains all
  three backend ABIs and passes native-library alignment validation.

Run the native capture suite on an isolated session bus:

```sh
xvfb-run -a dbus-run-session -- env NARAD_NOTIFICATION_TEST_BUS=1 \
  /usr/bin/python3 scripts/test-linux-notification-source.py
```

## Live device checks

The Linux host, A015 phone, and Redmi Pad SE tablet were updated. Installed Linux
backend/client/assets and both Android APKs were compared against the final build
with SHA-256.

A generated freedesktop notification was captured on Linux and appeared in the
notification records on both Android devices. An authenticated dismiss request
from the phone removed the original desktop notification; a subsequent remote
snapshot no longer contained it. The fixture was cleaned up, and temporary
notification grants and the desktop capture switch were restored to their prior
values. No personal notification contents were printed during verification.

To use the feature, enable **Settings → Share desktop notifications** on the
source desktop and grant **Share notifications** to each recipient in its device
settings. Grant **Dismiss notifications** separately if desired.

## Windows verification still required

The Linux environment cannot compile the Windows runner or execute MakeAppx.
Windows CI must compile the C++/WinRT source and validate the MSIX package. A real
Windows installation must additionally verify trusted package signing, listener
consent, capture, permission revocation, dismissal, and loop prevention. Unsigned
MSIX artifacts are review packages that require signing before installation.
The ZIP package continues to receive notifications; capture requires MSIX.
