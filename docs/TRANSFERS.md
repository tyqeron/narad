# File transfer notifications and storage

Android's connection service polls incoming and outgoing transfer progress every
three seconds, including when the Flutter window is closed. Notifications show
bytes, percentage and completion. Enable Narad notifications in OS settings.
Android 10+ publishes completed files using MediaStore in `Downloads/Narad`;
Android 8–9 require the requested storage permission. The encrypted transfer
history and private staging copy remain in application storage.

Linux and Windows update desktop notifications from the background desktop app.
Windows shows a progress bar; Linux shows percentage and bytes. Received files
are stored in the OS Downloads folder under `Narad/<transfer-id>/<filename>` to
avoid replacing files with the same name. Linux honors `xdg-user-dir DOWNLOAD`;
Windows resolves the Downloads known folder. Closing the desktop window keeps
Narad running; choosing Quit ends notification polling.

iOS publishes files into `On My iPhone > Narad > Downloads > Narad` in Files.
Its transfer notices run while the app is active. iOS does not provide unrestricted
background execution or access to a global Downloads folder; the existing Save
to device action can export to another Files location. iOS changes require an
Apple build/test host and remain unverified on this Linux host.

These progress notifications cover Send file, downloaded shared files, and
shared-folder uploads.
Files explicitly uploaded into a shared folder continue to use that selected
folder as their destination.

## Validation on the development devices

The Linux host, Nothing A015 phone and Xiaomi 23073RPBFG tablet were updated
with this change. Both installed APK hashes matched the final build.
Generated fixture files transferred in both directions, completed successfully,
and matched SHA-256 checksums in public Downloads/Narad on each receiver. The
Android transfer notification channel and active transfer notification records
were present on both devices, with notification permission enabled. Desktop notification regression
tests, 37 core Rust tests, strict Clippy, Dart analysis, the Linux build, the
universal Android APK build and Windows backend cross-check passed. Windows and
iOS native GUI runtime verification still require their platform hosts.
