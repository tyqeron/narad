# Narad client

Flutter desktop UI for the Rust daemon. Run the daemon from the repository root:

```sh
cargo run -p narad -- serve --name "My laptop"
```

Then, from this directory:

```sh
flutter pub get
flutter run -d linux
```

The app defaults to `../../.narad`; enter the absolute daemon state directory if
launching the packaged app elsewhere. Set `NARAD_STATE` to prefill it. The app
reads the daemon's private API token from that directory; tokens never need to
be pasted into the interface.

1. Create an invitation on one device and enter it on the other.
2. Compare the six-digit code on both devices and approve in Inbox on both.
3. Send a file, accept it on the receiving device, then select Send / resume.
4. Grant clipboard permission on the receiver before sending. Each payload
   still requires acceptance.
5. Enable Audio on both devices. Request audio on the sender and allow it in
   the receiver's Inbox. Capture begins after approval.

QR display is available; desktop invitation entry uses pasted JSON. Automatic
clipboard monitoring and QR camera scanning are not implemented.

## Checks

```sh
flutter analyze
flutter test
flutter build linux --debug
flutter test tools/preview.dart
```

Preview rendering writes PNGs to `/tmp` and optionally uses
`NARAD_PREVIEW_FONT` for a readable font. Linux is the currently validated
native build. Windows needs a platform build/test pass. Android scaffolding
is present, but embedding the Rust daemon and managing its background lifecycle
are pending; it is not a working phone client yet.
