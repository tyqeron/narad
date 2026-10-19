# Screens and secondary displays

Open **Media → Screens → Use <device> as a display**, or choose **Use as display**
on a paired device's actions page. Choose a screen/window in the operating
system picker. Accept the request on the receiving device, then open its Media
tab and choose **Full screen**. Stop on either device to end the session.

Screen requests have a separate `screen.view` permission. Receivers ask for
approval by default; a paired device's settings can allow screens automatically.
This permission never bypasses the source operating system's capture consent.
Turning off **Receive shared screens** ends active screen sessions. Screen video
uses the existing authenticated signaling channel and a separate, video-only
WebRTC connection; camera and audio sessions remain independent. For sound, use
Narad's existing speaker/microphone controls separately.

## Platform support

| Source | Mirror | Create an extended desktop |
| --- | --- | --- |
| Android | System screen-capture prompt; one capture can feed multiple receivers | Not supported: ordinary Android apps cannot extend the system desktop |
| Linux Wayland | System portal screen/window picker | Available when the portal advertises virtual monitors |
| Linux X11 | Screen/window picker | Capture an existing secondary output; creating one is not included |
| Windows | Screen/window picker | Capture an existing secondary output; a new output requires a virtual display driver, not included |
| iOS | Existing WebRTC/ReplayKit capture path; not device-tested in this change | Not supported; a native broadcast extension is needed for system-wide capture |

Android, Linux and Windows clients can receive screens. No Windows or iOS
hardware was available for runtime verification. This feature displays video;
input forwarding uses the existing remote-input feature separately.

On supported Wayland desktops, **Extend desktop** creates a portal-owned virtual
monitor, followed by a second system picker to capture that monitor. Select the
new virtual output, then arrange windows using desktop display settings. The
helper needs Python 3, PyGObject/Gio, a running screen-cast portal and PipeWire.
On KDE, `kscreen-doctor` places it beside existing screens and explicitly disables
replication. Each session owns and removes its own monitor. GNOME/compositor
layout behavior depends on its portal implementation; runtime testing covered KDE.
Cancelling a picker removes any temporary virtual monitor.

Android requires capture consent and a media-projection foreground service with
the persistent Narad notification. Protected content and lock screens may appear
blank under OS rules. Closing the application ends capture; Android does not
silently restart projection after reboot.

## Validation

- Rust tests cover screen permission approval/revocation, readiness and isolation
  from audio signaling and shutdown.
- Flutter tests cover consent controls, independent session cleanup, polling and
  the ended-session viewer.
- `python3 tests/screen_virtual_display_test.py` checks KDE output identification,
  including output ID renumbering and duplicate virtual connector names.
- Live Linux KDE / Android phone / Android tablet tests verified decoded video
  from phone to host and tablet concurrently, stopping one receiver without
  interrupting the other, and a real independent Wayland virtual desktop
  streamed to the phone. RTP statistics confirmed decoded video frames.

Platform interfaces: [ScreenCast portal](https://flatpak.github.io/xdg-desktop-portal/docs/doc-org.freedesktop.portal.ScreenCast.html),
[Android media projection](https://developer.android.com/media/grow/media-projection).
