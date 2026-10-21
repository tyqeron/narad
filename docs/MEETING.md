# Phone camera, microphone and speaker on a laptop

Pair both devices on the same LAN and update both to build 13 or newer. On the
phone, open the laptop's **Device settings** and enable **Play shared audio**,
**Share this device’s microphone**, and **Share this device’s camera** as needed.
These are independent permissions. Android asks for camera/microphone OS access
only when those features are enabled; speaker playback does not require microphone
access. Enable capture while Narad is visible before minimizing it. Its foreground
notification remains visible while background sharing is prepared. Reboot does
not silently re-enable camera or microphone capture.

## Listen to laptop videos on your phone

On the laptop, open the phone's **Device actions → Send laptop audio**. Choose
**Prepare / refresh audio capture**, select one or more online devices under
**Listening devices**, then **Play on selected devices**. You can add another
listener in the same panel without stopping existing streams. Each receiver
needs its own **Play shared audio** permission for the laptop. On
Linux this captures the monitor of the current default output, including other
applications' sound. Local playback continues. Changing the default output later
requires stopping and preparing again. On Windows choose an installed Stereo Mix
or virtual audio cable recording endpoint; for a cable, route the video player's
output to its playback endpoint in Windows sound settings.

Sharing continues when you press Back or minimize Narad. Return through **Media → Laptop audio sharing** or **Send laptop audio** to manage the same listeners. Each listener has its own stop button;
stopping or disconnecting one does not stop other listeners. All listeners share
one selected capture source. Choose **Stop all sharing** or quit Narad to
end its streams and remove its temporary Linux route. Stop all listeners before
changing the source. Incoming audio and microphone sends must be stopped before
starting this playback-sharing mode to avoid feedback. This mode disables speech noise
suppression, echo cancellation and automatic gain control to preserve video/music.

## Use all three phone devices in Google Meet

Open the phone's **Device actions → Use for meeting** on the laptop.

### Linux (PulseAudio or PipeWire with pipewire-pulse)

Install `pactl` using your distribution's PulseAudio utilities package. Select
**Create meeting audio devices**. Narad creates two separate user-session virtual
cables. It never changes system defaults or moves other applications' streams.

1. Select **Use phone as meeting speaker**.
2. Select **Use phone microphone in meeting**.
3. In Google Meet, choose the exact **Narad_Phone_Microphone_…** microphone and
   **Narad_Phone_Speaker_…** speaker shown in the setup panel. Reload Meet's device
   settings if it was open before the endpoints were created.
4. Select **Use phone camera**. In its camera card choose **Use in call apps**,
   add the copied URL as an OBS **Browser** source, then start **OBS Virtual Camera**.
   Choose **OBS Virtual Camera** as the camera in Meet.

OBS and the Linux virtual-camera support it requires (normally v4l2loopback) must
be installed separately. Narad provides the camera feed; it does not install a
kernel driver or claim to be a selectable system camera without that adapter.

### Windows

Install **two independent virtual audio cables**, for example VB-CABLE A and B.
One cable cannot carry both directions independently.

| Application setting | Endpoint |
| --- | --- |
| Meet speaker | Cable A playback |
| Narad capture laptop / meeting speaker audio | Cable A recording |
| Narad play phone microphone into virtual cable | Cable B playback |
| Meet microphone | Cable B recording |

Choose your normal local speaker in **Local playback to restore afterwards**,
then start both audio buttons. Camera setup uses OBS Browser source and OBS
Virtual Camera as above. Drivers are installed by the user, not downloaded or
modified automatically by Narad.

Keep this panel open and minimize Narad throughout the meeting. **Stop meeting
setup**, leaving the panel, or normal **Quit Narad** stops its streams, restores
Narad's playback endpoint, and unloads its owned Linux modules. Unrelated Narad
audio sessions should be stopped first: its native audio backend has one playback
endpoint for all incoming audio. Phone microphone capture uses speech processing;
use headphones or lower the phone speaker volume if feedback occurs. LAN latency
and the camera's OBS feed mean this is not a zero-latency hardware cable.

A crash or forced process kill may leave silent temporary Linux endpoints until
logout/audio-server restart. They do not change your system defaults. If removing
them manually, unload only the specific Narad `pactl list short modules` IDs; do
not unload unrelated audio modules.

## Other directions and platforms

**Use microphone**, **Send audio**, and **View camera** work between permitted
Narad peers. A mobile device can receive laptop camera/audio inside Narad.
Ordinary Android/iOS apps cannot expose that received stream as a system camera,
microphone, or speaker for unrelated mobile meeting apps. iOS background behavior
also follows its OS lifecycle restrictions; desktop-style virtual peripheral
registration and unrestricted background capture are not implemented on mobile.

## Validation

Unit tests cover separate mic permissions, capture shutdown, SDP media/direction
checks, endpoint selection and owned-route rollback. The opt-in Linux hardware
integration test uses generated PCM through owned virtual devices and native
WebRTC; it does not record a hardware microphone:

```sh
cd clients/flutter
flutter test integration_test/linux_audio_test.dart -d linux
```

A passing route test alone does not validate a live Google Meet call, OBS virtual
camera installation, Windows drivers, iOS background capture, or echo performance
on every phone. Those require the respective applications and hardware.

References: [PulseAudio modules](https://www.freedesktop.org/wiki/Software/PulseAudio/Documentation/User/Modules/),
[OBS Browser source](https://obsproject.com/kb/browser-source),
[OBS Virtual Camera](https://obsproject.com/kb/virtual-camera-guide),
[VB-CABLE](https://vb-audio.com/Cable/).

Physical Android interoperability (requires an already authorized camera/mic,
normal debug APK, and explicit consent to stream live media without recording):

```sh
FLUTTER_BIN=/opt/flutter/bin/flutter python3 tests/android_e2e.py \
  --serial <ADB-device> --desktop-audio --desktop-camera
```

This creates and removes a temporary pairing, verifies playback does not enable
microphone sharing, starts both audio directions while Android is backgrounded,
checks received camera/video-only tracks when requested, and checks remote stop.
It never changes permissions for real paired peers or saves live media.

### Multiple laptop-audio listeners

The capture pool and controller tests check two recipients, independent stop,
duplicate/source-change rejection, cancellation during initialization and retry.
The native fan-out test uses a generated tone and owned virtual devices, verifies
RTP at two receivers, then checks continuing RTP and decoded PCM after stopping
one receiver:

```sh
cd clients/flutter
dbus-run-session -- flutter test integration_test/linux_audio_fanout_test.dart -d linux
```

Each recipient still has a separate authenticated session and permission grant.
There is one local playback capture, released when its last listener stops.
Different capture sources and incoming-audio loops are not mixed into this mode.
