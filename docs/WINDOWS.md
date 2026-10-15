# Windows app

Narad supports Windows 10/11 x64. The package contains the Flutter desktop app,
its plugins and the Rust backend. Open **narad_client.exe**; no separate server,
account, Android SDK or terminal is needed on a testing PC.

## Build the package on Windows

Install Git, Rust 1.88 with the MSVC toolchain, Flutter 3.44.8, and Visual Studio
2022 with **Desktop development with C++**, its MSVC compiler, Windows SDK and
CMake components. `flutter doctor -v` should report Windows development ready.
Use an ordinary PowerShell window in this repository:

```powershell
.\scripts\build-windows.ps1
# Optional debug package:
.\scripts\build-windows.ps1 -Mode debug
```

The release ZIP and SHA-256 appear at:

```text
dist/narad-windows-x64-release.zip
dist/narad-windows-x64-release.zip.sha256
```

The Windows CI job runs native Rust tests, daemon integration tests, Flutter
analysis/tests, and this release build, then uploads the ZIP and checksum as
`narad-windows-x64-development`. Building the full Windows Flutter application
requires Windows; a Linux cross-compiled backend alone is not the desktop package.

For development, `cd clients/flutter; flutter run -d windows` also builds and
copies the matching Rust backend through CMake. The Windows runner is x64.

## Install and connect devices

1. Extract the **whole ZIP** to a folder. Keep `data`, DLLs, `narad.exe` and
   `narad_client.exe` together. Run `narad_client.exe` to try it without installation.
   These development binaries are unsigned; Windows may show its normal publisher
   warning. Verify the checksum and source before running them.
2. Optionally run `./install-windows.ps1` from the extracted package. It copies
   the app to `%LOCALAPPDATA%\Programs\Narad` and adds a Start menu shortcut;
   administrator access is not required. Close Narad before installing an update.
3. The backend starts automatically. Its private state lives in
   `%LOCALAPPDATA%\Narad\state`, independently of the extracted/installed app.
   Closing the window stops the backend it launched. An already authenticated
   daemon at that state path is reused and remains owned by its original launcher.
4. Put Windows, Android and Linux devices on the same private Wi-Fi/LAN. Set the
   Windows network profile to **Private** and allow Narad's backend through the
   Windows Firewall prompt for private networks.
5. Select a Nearby device, **Send pairing request**, then **Accept request** on
   the other device after checking the name/code. Use invitations if multicast
   discovery is unavailable. Paired devices show authenticated Online/Offline status.
6. Open **Device settings** to allow the paired device's capabilities. File and
   clipboard grants persist, so subsequent deliveries do not ask again. The
   desktop app must remain running for automatic clipboard writes and media.
7. Add files to Settings' **Shared folder** for permitted browsing/downloads.
   Configure command presets on the target Windows PC; peers can run only those
   presets, via `cmd.exe /D /S /C`, as the signed-in account. Unix shell commands
   need equivalent Windows commands (`echo`, `dir`, etc.). Commands have a ten-second
   deadline and bounded output; revocation/timeout terminates their Windows Job tree.
8. Enable audio/camera adapters in **Media** and permit desktop apps to use the
   microphone/camera in Windows Privacy settings. Sharing uses the local network;
   no STUN/TURN service is configured. Stop streams or revoke access to end them.
9. **Lock** uses Windows' interactive workstation-lock API. Unlock the PC locally
   with Windows Hello, PIN or password. Remote unlock is not advertised or offered
   for Windows. OS authentication is never bypassed.
10. Appearance defaults to the Windows theme. Settings offers saved Device/Light/Dark
    overrides. Activity groups readable events by day and category.

An optional `configure-windows-firewall.ps1` helper is included. In an
Administrator PowerShell window, run it from the installed/extracted app folder
(or pass `-InstallDirectory`). It creates only program-specific inbound TCP
45678–45679 and UDP 5353 rules for **Private / LocalSubnet**. `-Remove` removes
those rules for that installation. The localhost API on 45700 is never opened.
This helper is optional and is not run automatically by the installer.

## Storage and troubleshooting

Identity bytes are wrapped by Windows DPAPI for the current user/account, saved
as `identity.dpapi`, with a protected owner/SYSTEM DACL on app state directories.
Encrypted trust/permissions/presets are keyed from that identity. Existing
`identity.json` installations migrate to wrapped storage without changing their
identity. A broken wrapped file causes a visible error; the app never silently
creates a replacement identity. Do not copy identity/state to other accounts or PCs.

Reinstalling/updating the app preserves state. To uninstall, close Narad, remove
its installation directory and Start-menu shortcut. State remains until you
explicitly delete `%LOCALAPPDATA%\Narad`; deletion loses pairing and downloads.

If startup fails, extract the entire package, close duplicate Narad instances,
and check ports 45678, 45679 and 45700. Run the adjacent `narad.exe --state
"$env:LOCALAPPDATA\Narad\state" serve` in a terminal for its startup diagnostic.
A Microsoft Visual C++ x64 runtime is required on machines without the developer
tools; see Microsoft's [supported redistributable packages](https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist).
Guest Wi-Fi, VPN routing and blocked multicast can prevent discovery/communication.

## Verification

On Windows, before packaging:

```powershell
cargo test --workspace --locked
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build --locked -p narad
python tests/windows_e2e.py
cd clients/flutter
flutter analyze
flutter test
```

The Windows suite uses two temporary daemon identities and generated files.
It checks pairing, persistent grants, file transfer/restart, clipboard API gates,
media authorization, scoped browsing, Windows presets/revocation and DPAPI-backed
restart persistence. It does not touch the system clipboard, capture media or
lock a PC. Test real Windows-to-Android/Linux media, firewall behavior and locking
manually on your devices. Windows-native CI and physical QA results should be
recorded separately from Linux cross-compilation.

The platform behavior follows Microsoft's [DPAPI documentation](https://learn.microsoft.com/en-us/windows/win32/seccrypto/example-c-program-using-cryptprotectdata),
[Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects),
and [workstation locking requirements](https://learn.microsoft.com/en-us/windows/win32/shutdown/how-to-lock-the-workstation).
