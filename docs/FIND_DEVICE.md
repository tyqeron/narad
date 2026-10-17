# Find device

Update Narad on both ends. On the device you want to locate, open the requesting
peer's **Device settings** and enable **Ring this device (Find device)**. This is a
separate, default-off permission; pairing alone does not allow ringing.

On the requesting device, open the online device's action menu and select
**Find device**. It plays an alert for up to 30 seconds. **Stop ringing** in the
same menu ends it early. The Android home-screen widget also offers Find device.
Offline devices cannot receive a request; this uses the existing authenticated
LAN connection, without GPS, cloud location, or waking a powered-off device.

- **Android phones/tablets:** native alarm playback works through the running
  Narad background service. A separate Find device notification has Stop ringing.
  The connection notification's Stop Narad also stops the alarm. No camera or
  microphone access is needed. Enable notifications for the local stop control.
- **Linux:** Narad must be running, including in its tray. Playback uses paplay,
  aplay, or FFmpeg's ffplay, in that order. Install one supported audio player.
  Narad shows a Stop ringing card while the alert is active.
- **Windows:** the running Narad/tray app plays a generated PCM WAV using Windows
  PowerShell and System.Media.SoundPlayer. Narad shows a Stop ringing card.
- **iOS source preview:** uses AVAudioPlayer while Narad is open. Backgrounding
  stops the alert and the embedded backend; this is not Apple's Find My service.
  macOS signing/build tools and physical iPhone QA are required before delivery.

The alert respects system volume, mute, Do Not Disturb, audio routing and OS
restrictions. Narad does not change those settings. A successful playback start
is an acknowledgement of the alert request, not proof that a speaker is audible.
Requests are rate-limited to one start per paired requester every 30 seconds;
Stop ringing is not rate-limited. Revocation/unpairing stops an active alert on
the next receiver poll. All alerts stop on timeout. Stop Narad stops the Android alarm, and Settings →
Quit Narad stops desktop playback. Abrupt termination or the native desktop tray
Quit can leave the separate desktop player finishing its bounded 30-second file.
The daemon alone queues desktop alerts; the running GUI handles their playback.

For a physical Android check, install/open the normal debug app and run the
opt-in Android integration harness with `--find-only` (`--find-device` also runs
the existing file/restart checks). This briefly sounds the
alarm, backgrounds Narad, verifies media-playback foreground state and stops it
from the paired Linux test peer. It does not read personal media or location.
