# Camera controls and webcam output

Update both endpoints. On the source device enable **Media → Camera sharing**, allow
OS camera access, and grant the viewer **Share this device’s camera** in Device
settings. On the viewer choose **Device actions → View camera**, then open Media.
Video appears only on the requesting device. The source shows a sharing-status
card identifying the requester and a Stop sharing camera control, without a preview
or image/recording/webcam controls.

- **Switch camera** changes front/back on mobile, or cycles available webcams on
  desktop. The viewer sends this control through the existing authorized camera
  session. A missing second camera reports an error without ending the video.
  Stop source-side recording before switching cameras.
- **Save image** opens the system save picker for a PNG of the current video frame.
- **Record video → Stop recording → Save recorded video** creates an MP4, then opens
  the save picker. Until saved it is temporary. Discard removes it; closing Narad
  removes unsaved recordings. Disconnection finalizes a recording for saving in Media.
  Capture is video-only, without microphone/cellular audio. Limits: ten minutes or
  approximately 128 MB, checked every two seconds. Android/iOS use their native
  recorder; desktop uses FFmpeg with libx264 on PATH, capturing up to eight frames
  per second. Desktop recordings use wall-clock timestamps; slow capture reduces frame rate.

On Android, enable camera/audio sharing while Narad is visible and approve the OS
permission. The foreground service then keeps media available when you press Home,
lock the screen, open a save picker, or close the activity. Its persistent connection
notification identifies background camera/microphone availability; **Stop Narad**
stops sharing. Per-device camera/audio grants and revocation still apply. Enabling
sharing does not capture until an authorized session requests it. Keeping media
available holds a partial wake lock and uses more battery.

Android force-stop, system process termination, reboot, OS privacy switches, another
app using the camera, and manufacturer battery restrictions can interrupt sharing.
After a process restart, open Narad to re-enable media: Android requires a visible
activity to prepare camera/microphone foreground service access. This is not a way
to bypass runtime permissions or OS clipboard/unlock restrictions.

On iOS, camera/audio sharing remains foreground-only; a system save picker can end
the session. Reopen View camera for another capture. Linux/Windows keep their
existing tray/background operation; the desktop session must remain running.

Camera grants allow the viewer to capture/save received video. Use those grants only
with devices you trust. A session ending/revocation stops frame output and capture;
files already deliberately saved remain user files.

## Select a phone camera in laptop call applications

Linux and Windows use OBS Virtual Camera as the OS camera adapter. Narad does not
install a virtual-camera driver itself. Install OBS separately; Linux OBS also
requires its supported v4l2loopback setup. A standalone Narad virtual camera and
automatic OBS scene configuration are not implemented.

1. Open the phone's camera in Narad on the laptop.
2. Choose **Use in call apps** in that camera card and copy the local URL.
3. In OBS add a **Browser** source with that URL, width 1280 and height 720. Fit the
   source to your scene, then select **Start Virtual Camera**.
4. In the meeting application's camera selector choose **OBS Virtual Camera**.
5. Keep Narad and OBS running. **Stop webcam feed** or disconnecting the camera
   closes the local feed. Stop the OBS virtual camera too when finished.

The browser source is a video-only preview up to eight fps. Its random URL binds
only to 127.0.0.1 and is regenerated on restart; it is not a LAN endpoint. No cloud
or OBS websocket access is used. System call apps still control their own camera
permissions and may need reopening after the virtual camera starts.

The reverse direction works **inside Narad**: a phone/tablet can view, switch and
save a granted laptop camera. Ordinary Android/iOS apps cannot register this
received stream as a system camera for unrelated phone call apps. This build does
not provide root/HAL modifications or a mobile system-wide virtual camera.

References: [OBS virtual camera troubleshooting](https://obsproject.com/kb/virtual-camera-troubleshooting),
[Windows native virtual-camera API](https://learn.microsoft.com/en-us/windows/win32/api/mfvirtualcamera/nf-mfvirtualcamera-mfcreatevirtualcamera),
[Android external-camera provider integration](https://source.android.com/docs/core/camera/external-usb-cameras).

## Validation boundaries

Generated tests cover contact grant separation/revocation, vCard injection/Unicode
folding, pagination/content clearing, loopback URL/Host checks and decodable desktop
H.264 recording. Desktop frame capture replaces the locked WebRTC dependency's
busy wait and leaked pixel allocation with a bounded wait and scoped buffer.
Windows/Apple native runtime and end-to-end OBS meeting-app selection still require
platform/device QA; a working localhost feed alone is not that validation.

Opt-in tablet hardware regression (requires existing camera access and an unlocked
device): `FLUTTER_BIN=/opt/flutter/bin/flutter python3 tests/android_camera_tools.py
--serial <ADB-IP:port>`. It disables test-app uninstall, verifies temporary native
video with FFmpeg and removes its test copies. The contacts tablet UI test uses
generated data only; it does not exercise personal contacts or save a contact.

Build 9 was also checked in the normal tablet UI against a paired Android phone:
live camera, remote lens switch, Record/Stop/Save and Save image all succeeded.
The saved H.264 MP4 fully decoded at 720 × 1280 without audio; the saved PNG decoded
successfully. Uniquely named test files were removed afterward. Existing pairing
and OS access/role settings were preserved on both devices.

Phone speaker playback and meeting microphone/camera setup: [Meeting devices](MEETING.md).
