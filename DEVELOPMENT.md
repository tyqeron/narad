# Development journal

Each milestone is a separate Git commit. Planning documents are preserved in
the first commit. `git log --reverse --oneline` shows the development sequence.

## 1. Workspace foundation

- Rust workspace split into portable `narad-core` and the `narad` daemon/CLI.
- Protocol v1; control, file and media responsibilities remain separate.
- Flutter desktop client planned first; Android/iOS native daemon embedding and
  platform keystores require device work before those targets can ship.
- Private state and generated build output are excluded from Git.

## Validation policy

Run formatting, relevant behavioral tests, and lint checks at milestones.
Use two actual daemon instances for integration tests, including negative trust,
permission and recovery cases. Record unsupported or untested behavior honestly.

## 2. Identity, trust and authorization

- Stable Ed25519 identities and self-signed TLS certificates.
- Signed protocol envelopes bind the sender, payload, nonce and timestamp.
- Replay and stale-message rejection; encrypted ChaCha20-Poly1305 trust state.
- Capability permissions are independent of pairing; session transitions are guarded.
- Validation: four behavioral core tests passed; strict Clippy cleanup included in
  the transfer milestone.

## 3. Recoverable file storage

- Bounded chunks and BLAKE3 checksums for chunks and complete files.
- Encrypted progress manifests, atomic writes and durable checkpoints.
- Safe file names and per-transfer download directories prevent path traversal
  and accidental overwrite. Cancelled transfers reject further chunks.
- Validation: six core tests pass, including restart/resume, duplicate chunks,
  corrupt chunks, cancellation, encrypted-state tampering and authorization.

## 4. Network daemon and usable CLI

- mDNS/DNS-SD discovery and manual invitations; discovery is never a trust grant.
- Pinned TLS control and file listeners; signed, bounded protocol frames.
- One-time expiring pairing invitations and transcript verification codes with
  explicit approval on both devices.
- Token-authenticated loopback API, bounded concurrent connections and
  exclusive state-directory locking.
- File offer/accept/resume/cancel, encrypted outgoing history, clipboard
  permission plus per-payload acceptance, and approved WebRTC signaling.
- Revocation closes sessions; clipboard contents are excluded from activity logs.
- Validation: 12 Rust tests and strict Clippy pass; four real two-daemon TLS
  integration scenarios pass, including certificate mismatch and restart.

## 5. Flutter client and local audio adapter

- Device dashboard, QR invitation display/import, code comparison and pairing
  approval; capability permission management and unpair controls.
- File picker, durable outgoing history, transfer progress, resume and cancel.
- Clipboard preview/acceptance with actual platform clipboard writes.
- Separate WebRTC connections for microphone-to-speaker audio, host-only ICE,
  authenticated signaling, permission gates and explicit stop/cleanup.
- Media adapter lease prevents a disconnected UI from leaving its capability active.
- Responsive desktop/phone-sized layouts and activity diagnostics.
- Validation: five Flutter tests and static analysis pass; Linux debug build
  succeeds with native WebRTC plugin. Windows/mobile and physical-device audio
  are not yet validated.

## 6. Reliability and lifecycle fixes

- Actual multicast integration confirms discovery remains untrusted and audio
  availability follows the connected adapter.
- Refresh paired addresses only when discovery keys and TLS pins match; incoming
  metadata uses the observed network source address.
- Independent connection budgets for control, files and the local UI.
- Paginated history, bounded peer metadata, private IPv4 endpoints and archive
  actions that preserve completed downloads.
- Revoked file sessions stay closed through restart and need explicit resume.
- Keep one shutdown future across the accept loop and drain cancelled tasks;
  the expanded restart test exposed and resolved a missed-signal race.
- Audio cleanup stops local capture before network teardown; late microphone
  permission results are disposed when their session has already ended.
- Validation: 12 Rust tests, seven real daemon integration scenarios (including
  multicast and interrupted 8 MiB transfer), five Flutter tests, clean linting
  and rendered desktop/narrow layout previews.

## 7. Bounded buffered transport

- Read JSON frames through bounded buffered I/O instead of awaiting each byte.
- Keep the existing remote/local limits and reject missing frame terminators.
- Flush download directories before removing the partial-file link on Unix.
- Validation: Rust behavior tests and strict Clippy pass; real transfer/restart
  integration verifies the same framing and durability behavior.

## 8. Patched dependencies and project toolchain

- Checked registry dependencies against OSV and inspected the corresponding
  RustSec advisories. Updated Anyhow, Rand, Rustls/WebPKI, Tokio/Tokio-Rustls,
  Time, and the compatible Serde dependency chain.
- Rustls 0.23.46 includes the fixes listed in the
  [TLS handshake advisory](https://rustsec.org/advisories/RUSTSEC-2026-0285.html).
  Time 0.3.55 includes the
  [stack exhaustion fix](https://rustsec.org/advisories/RUSTSEC-2026-0009.html).
- `rust-toolchain.toml` pins Rust 1.88, required by patched Time. The global
  default toolchain remains unchanged.
- Added `scripts/check-dependencies.py` to repeat the public package-version
  advisory check; it sends no source code or private state.
- Validation on 2026-10-15: all 151 registry dependencies returned no matched
  OSV advisories; 12 Rust tests, strict Clippy and all seven daemon integration
  scenarios pass on the patched graph. This is not an independent security audit.

## 9. Run instructions, CI and implementation status

- Added the Linux development launcher, CLI/GUI setup instructions, experimental
  protocol reference, architecture decisions and explicit remaining-work status.
- Added Rust and Flutter CI jobs; CI configuration is committed, not yet run on
  a hosted repository. Linux native builds and equivalent local checks pass.
- Set client version 0.1.0 and included the workspace MIT license.
- Original PRD, architecture, roadmap, backlog and technical specification stay
  preserved as the planning baseline; cross-platform release criteria remain open.

## 10. Embeddable backend and Android JNI foundation

- Extracted the daemon into a reusable library with caller-owned shutdown and
  startup readiness signaling; the desktop CLI uses the same implementation.
- Added the Android JNI runtime host and in-memory identity generation so Android
  can wrap private identity bytes with Keystore without writing a plaintext key.
- Added NDK builds for arm64-v8a, armeabi-v7a and x86_64 with 16 KiB page alignment.
- Added local metadata operations for device naming and Wi-Fi address updates.
- Validation: 13 Rust tests and strict Clippy pass; ARM64 native library builds
  against installed NDK r27. Embedded start/stop/restart preserves identity and
  releases sockets without depending on process signals.

## 11. Android host, Keystore and foreground service

- Added a connected-device foreground service that owns the Rust runtime, Wi-Fi
  multicast lock and live LAN address updates independently of the Activity.
- Wrapped each install's identity with Android Keystore AES-GCM, excluded private
  state from backup, and surfaced authentication errors without replacing keys.
- Added native startup/status/stop, device naming, and Storage Access Framework
  export methods; notification offers an explicit service stop action.
- Gradle builds and packages Rust automatically; Android 8.0+ is required.
- Validation: ARM64 debug APK compiled successfully. Updated the NDK pin to r28
  installed during the build, matching the Flutter plugins' required version.
  Physical installation is pending the tablet's install-via-USB setting.

## 12. Standalone Android interface

- Android starts its private backend automatically instead of asking for a desktop
  daemon path; startup errors and retry remain visible to the user.
- Added offline QR invitation scanning, device naming, and received-file export
  using Android's document picker without broad storage access.
- Retry can reselect an evicted source file while retaining its transfer ID.
- Audio capture is disabled when Android leaves the foreground.
- Validation: eight Flutter tests and static analysis pass, including readiness,
  authenticated startup, shutdown waiting and identity-error propagation.

## 13. Android file publication compatibility

- Physical tablet testing established the connected-device service and completed
  Android/Linux TLS pairing, then exposed Android's rejection of hard-link
  publication at the end of an incoming file transfer.
- Linux/Android now publish verified files using atomic `renameat2` with
  `RENAME_NOREPLACE`; no partially copied file or overwrite is permitted.
  The direct syscall avoids requiring Android 11's bionic symbol on Android 8.
- Added a regression proving an existing destination and verified source both
  survive a refused publication, followed by successful retry.
- Validation: 14 Rust tests, strict Clippy and all seven desktop integration
  scenarios pass. Tablet revalidation follows with a rebuilt APK.

## 14. Physical Android interoperability and lifecycle checks

- Added two on-device integration tests for Keystore-wrapped identity persistence
  across service restart and an actual native WebRTC data-channel exchange.
  Neither test captures microphone, camera or system clipboard contents.
- Added an opt-in ADB harness using only generated fixtures and a temporary peer.
  It validates Android/Linux pairing, a full Android process restart preserving
  identity/trust/file approval, both file directions, clipboard gates and unpair.
  The harness waits through the expected local API disconnect during restart and
  cleans its own temporary peer, transfer records and fixture files.
- Validation on 2026-10-15: both device tests and all six Android/Linux checks pass
  on the connected 23073RPBFG ARM64 tablet, Android 15/API 35 with 4 KiB pages.
  Incoming and outgoing generated files match byte-for-byte.
- Physical testing exposed and verified the hard-link fix in step 13. Camera QR
  scanning, Android document export, real microphone audio quality, more Android
  models and physical 16 KiB-page devices still need manual device QA.

## 15. Universal APK delivery and repeatable multi-device setup

- Added a one-command Android build script, APK ABI/ELF validator and checksum
  output. Gradle tracks the NDK version as an input to its native build task.
- Built the universal release-mode development APK (113.7 MB) with NDK r28 and
  the normal Flutter entry point; it includes ARM64, ARMv7 and x86_64 backends.
- Verified its APK signature, SHA-256, 16 KiB ZIP alignment and all 16 packaged
  64-bit ELF libraries. This is an internally signed development artifact.
- Added build/install, Android/Linux pairing, multi-phone test steps, permissions,
  storage, background behavior and troubleshooting documentation.
- Added an Android CI artifact job; local equivalent builds pass, hosted execution
  is not claimed. Public OSV check covered 171 packages with no matched advisories.
- Installed the release APK on the tablet, confirmed its foreground service,
  and visually checked the working Devices dashboard. Temporary test peers and
  fixture records were removed before handoff.
- APKs remain outside Git under ignored dist/; the implementation, reproducible
  build instructions, test harnesses and development journal are committed.

## 16. Direct nearby pairing requests

- Added signed, TLS-pinned nearby requests without an invitation nonce supplied
  by the user. The receiver issues a fresh five-minute pairing transcript.
- Sending a request records the initiator's consent; accepting on the receiver
  allows a daemon-owned worker to complete pairing automatically on the sender.
  This works independently of Flutter's foreground/background lifecycle.
- Requests support decline, owner-checked cancellation, expiry and duplicate
  prevention. Pairing still grants no file, clipboard or microphone permission.
- Kept invitation/QR pairing compatible and retained a visible verification code.
- Validation: 16 Rust tests, strict Clippy and nine real-daemon integration
  scenarios pass, including mDNS-selected pairing, acceptance without sender
  confirmation, decline, cancellation, persistence and permission boundaries.

## 17. Nearby request interface

- Nearby device cards now offer Send pairing request, with a disabled Request sent
  state while approval is pending. Sending opens the outgoing Inbox request.
- Incoming requests have a dashboard notice, Inbox badge, visible verification
  code and Accept request / Decline actions; no text entry or camera is needed.
- Outgoing requests show waiting/declined states and a cancellation action;
  automatic completion belongs to the daemon rather than UI polling.
- Bumped the Android development build to 0.1.0+3.
- Validation: Flutter analysis and all 11 tests pass, including sending without
  invitations, accepting without code entry, and sender cancellation. Existing
  invitation confirmation and narrow-screen behavior remain covered.

## 18. Physical nearby discovery and updated Android delivery

- Extended the Android/Linux harness with nearby-request mode and token rotation
  handling during app upgrades/startup; invitation mode remains available.
- Verified physical mutual mDNS discovery, desktop-to-Android request acceptance,
  and Android-to-desktop acceptance while Flutter is backgrounded.
- All eight nearby-mode device checks pass on the Android 15 tablet, including
  process restart, persisted trust, generated files in both directions, clipboard
  gates and revocation. Test peers, records and fixtures are cleaned up.
- Updated the user guides and protocol reference for request/accept pairing,
  waiting/decline/cancel behavior, five-minute expiry and invitation fallback.
- Repeated all eight device checks successfully on a second phone, Nothing A015
  running Android 16/API 36. Added explicit process-termination and Activity
  readiness waits to the restart harness after an initial timing failure; a
  direct restart diagnostic also confirmed stable identity. One discovery run
  timed out; the subsequent complete physical mDNS/pairing/transfer run passed.
- Rebuilt universal 0.1.0+3 successfully; signature, SHA-256, 16 KiB ZIP alignment
  and all 16 packaged 64-bit native ELF alignment checks pass.
- Installed and launched the universal release APK on the connected Android 16
  phone after testing, preserving app data. The connection service is active.

## 19. Authenticated presence and persistent per-device grants

- Added authenticated heartbeat checks and online/offline/last-seen metadata.
- Added a separate encrypted automatic-grant map. Older one-off file approvals
  remain one-off; they do not silently migrate into always-allowed access.
- Explicit device grants enable automatic files, clipboard delivery, audio and
  camera authorization. Revocation stops associated sessions and queued actions.
- Added camera signaling, a scoped Shared folder with bounded downloads, and
  encrypted local command presets. Peers cannot submit arbitrary shell commands.
- Preset execution has bounded output, a ten-second deadline, process-group
  cleanup, and permission rechecks while running. Scripts/output stay out of logs.
- Added permissioned Linux session controls and Android platform-action queues
  that recheck permission before executing through the native service.
- Validation: 19 Rust tests and strict Clippy pass; all 13 real-daemon scenarios
  pass, covering online/offline/reconnect, migration, seamless grants, traversal
  rejection, scoped downloads, preset execution and immediate command revocation.

## 20. Device dashboard, persistent themes and grouped activity

- Separated nearby devices from paired online/offline groups, with authenticated
  status and disabled offline communication controls.
- Added per-device settings for eight persistent capabilities, shared-folder and
  command-preset controls, and camera viewing through the Media adapter.
- Grouped readable activity summaries by day/category and collapsed repeated
  transfer progress. Device appearance is the default, with saved Light/Dark
  overrides in Settings.
- Validation: Flutter analysis and all 15 tests pass, including theme persistence,
  permission switches, online/offline controls, grouped activity and phone layout.

## 21. Native Android controls and shared app branding

- Added native automatic clipboard delivery, permission-validated device-action
  dispatch, optional force-lock device-admin activation, and notification-driven
  system authentication for unlock requests. Camera permission setup is explicit.
- Reused the in-app hub mark for Android adaptive/legacy/monochrome launchers and
  notification icon, Linux window/desktop assets and the Windows icon resource.
  Included its license and reproducible asset-generation script.
- Validation: Android ARM64 debug and Linux native debug builds pass. Light/dark
  desktop and phone previews render without overflow and were visually inspected.
- Camera capture quality and real lock/unlock behavior remain physical manual QA;
  automated checks do not activate cameras or lock the user's devices.

## 22. Physical device controls and multi-device delivery

- Extended the generated-fixture Android/Linux harness with optional --controls:
  authenticated presence, automatic file grants, scoped browsing/downloads, and
  command presets executed in both directions. Existing checks cover discovery,
  acceptance, restart, bidirectional files, clipboard gates, revocation and pairing
  while the Android UI is backgrounded.
- All twelve updated checks pass on the Android 15 tablet. No personal files or
  clipboard contents were read, and no camera, microphone or lock was activated.
- Updated setup, protocol, decisions and implementation-status documentation for
  persistent grants, theme settings, scoped controls and OS authentication limits.
- Universal 0.1.0+4 release APK passes signature, SHA-256, ZIP alignment and all
  16 packaged 64-bit native-library alignment checks; three backend ABIs included.

## 23. Windows identity, storage and backend controls

- Added current-user DPAPI identity wrapping and migration, protected owner/SYSTEM
  directory ACLs, and durable Windows atomic replacement without deleting the old
  destination first. Corrupt wrapped identity fails closed.
- Added cmd.exe presets with suspended-start Windows Job containment and descendant
  cleanup on revocation/deadline; LockWorkStation controls the interactive session.
  Windows does not advertise remote unlock or bypass authentication.
- Rejected Windows DOS devices, alternate streams and normalized filename aliases
  in transfers and shared browsing.
- Validation: Windows GNU backend and test executables cross-compile successfully;
  Windows-target strict Clippy passes. All 21 host Rust tests and 13 real-daemon
  regression scenarios pass. Windows-native execution remains a separate CI check.

## 24. Windows desktop startup and shared interface

- Added the native window-owned backend supervisor, suspended job assignment,
  automatic per-user configuration, authenticated daemon reuse, readiness polling
  and visible startup failures/retry. CMake builds and bundles narad.exe.
- Preserved shared nearby pairing, device grants, files, clipboard, media, grouped
  activity and theme settings. Windows peers omit unsupported remote-unlock UI.
- Validation: all 20 Flutter tests and analysis pass. Both backend_host.cpp and
  Flutter method-channel integration cross-compile against Windows/Flutter SDK
  headers. Full Windows MSVC GUI linking/execution requires a Windows host.

## 25. Windows packaging, installation and native CI

- Added release/debug ZIP builds with SHA-256, per-user installation and Start-menu
  shortcut, and a separate optional private-subnet firewall helper. No firewall
  changes or administrative prompts run automatically during installation.
- Added a Windows-native integration suite covering generated file fixtures,
  DPAPI restart persistence, scoped browsing, cmd presets/revocation and capability
  gates, plus Windows CI for native tests, script parsing and ZIP artifacts.
- Documented Windows prerequisites, one-executable startup, Android/Linux pairing,
  per-user state, upgrades/uninstallation and OS media/authentication boundaries.
- Validation: workflow YAML and Python suites parse; Windows Rust cross-builds,
  native C++ compile checks, host regression tests and Flutter checks are recorded
  above. Full MSVC/Flutter Windows release build and physical Windows QA remain
  unverified on this Linux host. Wine initialization stalled and was stopped;
  no Wine result is counted as a successful Windows runtime test.

## 26. Linux bundle launcher and per-user installer

- Replaced the Linux packaging drafts with a native-host Rust/Flutter bundle build,
  per-user installation and a shared launcher. State lives outside the installation
  so upgrades preserve identity, grants and downloads.
- The menu shortcut starts backend and GUI together. The launcher waits for the
  authenticated API, cleans up its own daemon on GUI exit, and leaves a reused
  daemon running. Fixed debug output paths and removed the trap-bypassing exec.
- Added a checksummed self-extracting .run builder, release/debug modes and optional
  wrapping of an existing bundle. It requires no root, package manager or FUSE.
- Validation: full Linux x64 release build succeeds and produces the installer;
  shell syntax and emitted SHA-256 checks pass.

## 27. Repeatable Linux installer checks

- Added temporary-directory packaging checks for installation/desktop entries with
  spaces, upgrade preservation, unrelated/symlink destination rejection and corrupt
  payload rejection. Desktop-entry validation passes.
- Exercised the actual packaged backend with a headless GUI fixture: owned daemon
  stops on GUI exit, and an authenticated existing daemon is reused and retained.
- All six packaging scenarios pass. CI builds a Linux debug installer and runs the
  same checks; workflow YAML validation passes. Runtime media quality remains
  outside packaging checks.

## 28. Compact device action menus and desktop background controls

- Reduced paired-device rows to identity/status, a Settings icon and a menu of
  actions with icons. Offline communication actions remain disabled.
- Added desktop Settings for login startup and explicit Quit, Linux GTK window
  hiding/tray/reopen behavior, and Windows notification-area/single-window controls.
- Installers enable per-user hidden startup after login and preserve an explicit
  opt-out through upgrades; no system/pre-login service is created.
- Validation so far: 22 Flutter tests, analysis and phone/desktop previews pass;
  Linux release compiles and updated Windows tray/preferences/runner sources
  cross-compile against official Flutter headers. Final native runtime and
  artifact checks are recorded in the following milestone.

## 29. Android home-screen command widgets

- Added a configurable native widget: select a paired device and one of its
  permitted command presets, then run it directly from the home screen.
- Widget taps start/reuse the existing foreground connection service and execute
  authenticated preset IDs through normal receiver-side authorization. Duplicate
  taps while running are coalesced; deleting/revoking presets prevents execution.
- Each widget keeps only its selection/label/status, never scripts or command
  output. Added reconfiguration, deletion cleanup, theme updates and app Settings
  instructions. Bumped the development app to 0.1.0+5.
- Validation: Android ARM64 debug compilation passes; the universal release and
  metadata/signature checks are recorded in the final delivery milestone. No
  physical Android device is connected, so launcher interaction is manual QA.

## 30. Background lifecycle regression checks and updated delivery

- Added isolated Xvfb/D-Bus native tests using the real window-manager close
  protocol: hidden login startup, close-to-background and same-process reopen all
  pass. Explicitly realizes the hidden GTK parent and restores registered windows
  even before they have received focus. CI runs these checks on its debug bundle.
- All seven installer scenarios pass, including per-user login entries and an
  explicit startup opt-out surviving upgrades. The refreshed Linux release
  installer includes the final native runner fix.
- Universal Android 0.1.0+5 release includes widget provider/configuration metadata;
  signature, SHA-256, 16 KiB ZIP/ELF alignment and three backend ABIs verify.
- Updated guides for icon action menus, Android widget setup, desktop background
  operation, after-login startup, opt-outs and explicit Quit behavior.
- Validation boundaries: 22 Flutter tests/analysis and native Windows compile checks
  pass. No Android device was connected for physical launcher interaction; Windows
  tray/login runtime and real reboot testing remain manual/native CI work. Tests
  never rebooted or locked the user's desktop or captured microphone/camera data.

## 31. Device-action widgets and live connection notification

- Replaced the preset-only widget with a device selector and scrollable icon
  actions matching the device menu. Existing widget selections migrate in place;
  command presets are selected only when Run command is tapped.
- Widget taps open the matching Flutter action using a validated widget identity,
  private nonce and stored paired target. Offline communication stays disabled;
  the receiver still rechecks all permissions.
- Added rounded light/dark layouts, connection status, refresh and reconfiguration.
- The ongoing foreground notification now shows authenticated connected-device
  names/count, an expanded list, private lock-screen content and Stop Narad.
- Validation: 27 Flutter tests/analysis, five native policy tests and Android ARM64
  debug build pass. Physical interaction and universal release verification follow.

## 32. Physical widget regression checks and Android delivery

- Added a debug-only AppWidgetHost fixture and repeatable tablet checks for real
  RemoteViews rows, scrolling, selected-device action routing and the ongoing
  notification's connected-device name. Flutter labels are asserted through their
  accessibility content descriptions. Fixture widgets/peers/grants are cleaned up.
- All 15 nearby Android/Linux scenarios pass on the Android 15/API 35 tablet,
  including trust after process restart, bidirectional files, automatic grants,
  scoped browse/download, command presets and background pairing completion.
- Five native widget policy tests pass and run in Android CI; 27 Flutter tests and
  analysis pass. Media capture and actual device locking were not automated.
- Universal 0.1.0+6 release packages three backend ABIs; signature, checksum,
  16 KiB ZIP alignment and all 16 packaged 64-bit ELF libraries verify. Release
  manifest excludes the debug host. Android 14+ OS dismissal rules still apply
  to ongoing notifications; device names are hidden in public lock-screen content.

## 33. Camera signaling authorization fix

- Reproduced camera sharing failure with a real two-daemon regression: the outgoing
  media signaling path incorrectly authorized every session as audio.output,
  rejecting camera.stream offers, answers and ICE candidates.
- Authorize against the stored session capability, explicitly limited to audio
  and camera. Peer ownership, session state and current permissions still apply.
- Regression verifies both signaling directions with audio denied, rejection before
  camera approval and rejection after camera revocation. Existing audio checks pass.
- Validation: 21 Rust tests and strict Clippy pass; the integration suite passes
  13 scenarios with its optional multicast case skipped. Hardware camera validation
  and updated artifacts are recorded in the next milestone.

## 34. Camera hardware and desktop interoperability checks

- Added an explicit Android camera loopback test: video without audio reaches a
  native renderer with nonzero dimensions, then capture stops. It passes on the
  Android 15 tablet; first-frame and size events are awaited independently.
- Added an opt-in physical camera fixture and Linux viewer test using the production
  media controller. Android 16 Nothing A015 camera video renders on Linux through
  real paired TLS signaling/WebRTC with audio explicitly denied. Temporary camera
  grants and peers are removed; no video/audio is recorded.
- Desktop capture now rejects a stream without video tracks with an actionable
  camera-access error. The shared backend fix also compiles for Windows GNU.
- Flutter analysis and 27 tests pass. The physical desktop check uses an isolated
  D-Bus session and a real display or Xvfb; source Narad must stay foreground.
- Bumped Android to 0.1.0+7 and documented updating both endpoints/restarting the
  desktop daemon. Universal APK and Linux release installer both build successfully.
- APK signature, checksum, 16 KiB ZIP alignment and all 16 packaged 64-bit ELF
  libraries verify across three backend ABIs. Build 7 is installed on the phone
  with existing app data preserved; the disconnected tablet still needs updating.
- Desktop webcam capture (no webcam attached here), Windows camera runtime and
  physical phone-to-tablet video remain outside the verified hardware matrix.

## 35. Permissioned phone companion protocol

- Added paired TLS phone RPC with distinct notification read/manage/reply, SMS
  read/send and call read/control grants. Native requests are bounded, expire,
  dispatch once, and recheck grants before execution and result delivery.
- Content remains in memory for the request and never enters activity history or
  persistent storage. Disabling the bridge drops pending content; receiver-side
  revocation and unpairing prevent delivery. Only readiness is advertised.
- Generated two-daemon tests verify explicit opt-in, separate send permissions,
  exactly-once dispatch, content exclusion from status/history, and revocation.
- Validation: Rust 21 behavioral tests, strict Clippy and both new integration
  cases pass. The full run encountered a transient port-allocation collision in
  one fixture; both new scenarios pass when rerun. Native phone/client UI work
  and platform limitations are recorded separately below.

## 36. Android phone integration and companion interface

- Added explicit native setup for notification access, SMS, call logs and optional
  default-dialer call controls. No permission or role is changed automatically.
- Added shared notification, SMS and call views, separate per-device grants,
  confirmation before sending, background generic banners and widget routing.
- Android native tests pass (8); Flutter analysis and 31 tests pass. Generated
  fixtures cover confirmation, revocation clearing and banner deduplication.
- Cellular audio remains on the phone or its existing OS audio route; Narad
  desktop cellular audio routing is not implemented. No real messages/calls sent.

## 37. iOS source preview and platform boundaries

- Added a foreground iOS runner, Keychain identity, bounded Rust C ABI and
  macOS XCFramework build script/CI configuration. Invitation/QR pairing avoids
  requiring a multicast entitlement. User-confirmed composer/call handoff is optional.
- General iPhone SMS inbox, call history and system notification mirroring are
  unavailable in this implementation. macOS build/signing and iPhone QA remain.
- Rust workspace 22 tests and strict Clippy pass; mobile ABI lifecycle test passes.
  Windows backend cross-check passes; new Windows banner native code awaits CI.
- Full integration rerun passes 15 cases with one opt-in multicast case skipped,
  resolving the transient fixture port collision noted in milestone 35.

## 38. Physical phone setup layout correction

- The Nothing A015 Android 16 setup screen opens from Flutter Settings; access
  remains disabled and no role/permission was changed. Physical inspection found
  a status-bar overlap in native activities. Added system-bar insets and modern
  device-theme controls to setup/dial/in-call screens and clarified audio limits.
- Universal release 0.1.0+8 builds; signature, checksum, ZIP 16 KiB alignment and
  all 16 packaged 64-bit ELF libraries verify. Installed on the Nothing A015
  preserving app data. The title is below the status bar and switch visible.
- Phone-side access indicators are Ready and Narad is currently default dialer;
  integration remains off. These checks did not change permissions/role or read
  messages, call history, notifications, or place/answer a real call.
- Linux release installer builds and all seven disposable installation/upgrade/
  daemon lifecycle checks pass; checksum verifies. Artifacts live under dist/.

## 39. Contact access, camera tools and desktop webcam bridge

- Added separately granted live contacts pages, Android/iOS source adapters and
  explicit native contact-editor/vCard export. Existing address books are never
  silently merged or overwritten; desktop address-book publishing is not included.
- Added source/viewer camera switching, PNG capture, video-only MP4 recording,
  save/discard controls and an explicit random-token localhost OBS Browser feed.
  OBS provides the desktop system camera; mobile system-wide injection is absent.
- Replaced the locked desktop WebRTC frame capturer at CMake build time without
  altering Pub cache: synchronized/bounded frame wait and scoped pixel buffer.
- Validation so far: 22 Rust tests, strict Clippy, 16 real-daemon scenarios pass
  (one multicast opt-in skipped), clean Flutter analysis and 35 Flutter tests.
  Generated FFmpeg recordings decode; feed rejects unknown paths/Host headers.
  Linux release builds including the native replacement. Physical tablet tests,
  isolated desktop capture and final artifact delivery are recorded next.

## 40. Tablet camera format regression and physical verification

- Android 15/API 35 Xiaomi tablet test caught WebRTC returning JPEG bytes under a
  PNG filename. CameraFrames now decodes/re-encodes a real PNG before save/feed.
- Physical WebRTC receive/render, front/back switch twice, valid snapshots and a
  three-second video-only MP4 pass on the tablet. Host FFmpeg fully decodes the
  actual native H.264 recording, then test copies are removed.
- Flutter integration tests now specify --no-uninstall to preserve installed app
  data; the first test's default cleanup was blocked by existing device-admin
  policy. App data was preserved. A reusable host decoder harness is included.
- The isolated Linux native test now passes repeated actual WebRTC PNG captures,
  localhost feed retrieval and FFmpeg decoding of the generated display recording.
  Capture waits run off the platform thread; a static/incorrect display initially
  timed out. The test uses animated generated UI under forced X11/Xvfb.
- Desktop MP4 duplicates frames against elapsed time rather than accelerating
  when frame production is slower than the eight-fps preview limit.
- Tablet contacts list denial/reload checks use generated data. System contact
  editor resolution is confirmed; editor field automation timed out, so native
  contact saving remains manual QA. Existing contacts were not queried or saved.

## 41. Final build 9 delivery and paired-device UI checks

- Universal Android 0.1.0+9 and Linux release installer build. APK signature,
  checksum, ZIP 16 KiB alignment and all 16 packaged 64-bit ELF libraries verify.
  Installer checksum and all seven disposable installation/lifecycle tests pass.
- Build 9 installed over existing data on the Android 15 Xiaomi tablet and
  Android 16 Nothing A015. Both preserve their paired relationship and appear
  online after restart. No default roles or OS access grants were changed.
- Normal tablet app renders the phone's live camera after a remote lens switch.
  Record/Stop/Save through the real Android picker produces a fully decodable
  video-only H.264 MP4 at 720 x 1280. Save image through the real picker produces
  a valid PNG. Only the uniquely named test files and host copies are deleted.
- Final Flutter analysis and 35 tests pass; native Android tests pass (8). Tablet
  generated contacts UI verifies denial clears the list and Save is explicit.
  Existing address books are not read or modified. Native contact save/account
  selection and full OBS virtual-camera meeting selection remain manual QA.
- The desktop generated-display integration passes repeated real native frames,
  feed retrieval and MP4 decoding. Windows/iOS native runtime remains unverified.

## 42. Requester-only camera display

- Removed creation of a local video renderer on the camera source and ignore
  source-side camera onTrack events. Capture and authorized transmission remain.
- Source UI shows only the requesting device and Stop sharing camera. Video,
  snapshots, recording and webcam tools are restricted to the requester.
- Added role-specific UI regression checks; Android version advances to build 10.
  Flutter analysis and 37 tests pass, including source/requester role checks.
  Physical delivery is recorded below when complete.
