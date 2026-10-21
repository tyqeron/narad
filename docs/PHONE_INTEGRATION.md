# Phone companion integration

Update Narad on both endpoints. In Devices, open **Phone companion** for a paired
phone; Android home-screen widgets offer the same action. Separate per-device
grants control notification reading, dismissal and replies, SMS reading and
sending, call history/live state and call controls. Permissions are checked on
the phone for every request. Revoking access clears the next displayed snapshot.

## Android setup

1. Open **Settings → Phone integration** on the source phone and enable it.
2. Choose **Notification access** to allow Android's notification listener.
3. Allow only the SMS/call-log permissions you want. These are hard-restricted
   Android permissions: the installer must allowlist them, and some installations
   cannot grant them. Narad reports denied access; it does not bypass restrictions.
4. For optional place/answer/end/mute/keypad controls, choose **Use Narad as phone
   app** and approve Android's default-dialer role, then allow placing calls.
   Narad includes a local dial screen, incoming/ongoing call UI and notification.
   You can restore your previous phone app in Android Settings. The role is never
   changed automatically, and a tablet without telephony need not enable it.
5. In that phone's **Device settings** for each viewer, enable the specific grants.
   Reading messages never grants sending. Notification replies and dismissal have
   separate grants too. Keep Narad's connection service running for background use.

**Phone companion** contains Alerts, SMS and Calls. SMS uses the phone's configured
default SMS SIM. Send opens a reviewable composer; Android's result is **submitted**,
not carrier delivery confirmation. Notification replies use the source app's
Android RemoteInput action. Calls need the phone's default-dialer role; call-log
permission can be denied independently without hiding active-call controls.

SMS/history pages return at most 20 rows with Older/Latest controls; conversations
filter by thread. Very long SMS bodies are capped at 1200 characters per row.
Only up to 30 active notifications are returned. This is live access, not a message
archive or full account backup. Android can redact sensitive notifications and
OTP content; Narad respects that redaction. MMS, RCS, attachments, contact sync,
delivery receipts and SIM selection within Narad are not implemented.

## Desktop and Android viewers

Linux and Windows use the same phone panel. Android can also view another paired
Android phone. Background desktop and Android polling reports new notifications
and ringing calls with full notification titles and bodies in OS banners. Notification
actions and **Dismiss** buttons use separate per-device grants, and changed alerts
update in place. Ongoing alerts and determinate/indeterminate progress are mirrored;
Android viewers also preserve supported notification timers. Updates are polled every
three seconds (network and source processing add latency), retaining the same alert
instead of adding copies. Source removal withdraws the mirror; using a live action
keeps it visible while the source updates. Custom app notification layouts and widgets
are rendered as their exposed text/actions, not copied pixel for pixel. Windows uses
standard OS toasts and cannot force an un-dismissible ongoing banner. Startup quietly mirrors current alerts; withdrawals, offline devices
and revoked read access clear their OS entries. Replies use native Android RemoteInput
and Windows inline input; Linux opens a short reply composer in Narad.
Mirrored Narad notifications are excluded to prevent forwarding loops. OS banner
appearance and sound remain controlled by system notification settings.

**Cellular audio is not implemented by Narad.** Place/answer/end/mute operations
control the source phone; audio stays on that phone or an existing OS-provided
Bluetooth route. Narad does not configure Bluetooth HFP or transport cellular
call audio to a desktop microphone/speakers. Normal Android apps cannot capture
cellular call uplink/downlink for a Wi-Fi relay. The existing WebRTC audio feature
is a separate microphone stream and does not provide a cellular-call bridge.

## iPhone/iPad

The new iOS runner is a source preview requiring macOS/Xcode build and signing;
its Swift host has not been compiled or run in this Linux workspace. It embeds
the tested Rust mobile host, stores identity in device-only Keychain storage,
and exposes the shared Android-phone viewer while Narad is foregrounded. See
[the iOS build guide](IOS.md).

The intended supported direction is **Android phone → iOS viewer**, subject to
macOS/device validation. The reverse direction has these explicit limits:

| iPhone source feature | This implementation |
| --- | --- |
| Read SMS inbox/history | Unavailable through the public APIs used by Narad |
| Read cellular call history or answer/end cellular calls | Unavailable |
| Mirror general system/app notifications | Unavailable in this build; Apple's regional accessory framework needs separate eligibility, extension and entitlements |
| Send SMS request | Optional handoff opens Apple's composer; the user must confirm on iPhone |
| Place call request | Optional phone-side confirmation and system dial handoff |
| Silent/background handoff | Unavailable; Narad must remain visible |

To enable iPhone handoff, use **Settings → Phone integration**, then grant SMS
composer/call-request access to each paired viewer. A handoff acknowledgement is
not SMS delivery or confirmation that a call was placed. iOS never exposes a fake
SMS inbox or call history. Raw mDNS discovery is disabled on iOS in this preview;
use invitation/QR pairing until native Bonjour discovery is added.

## Data and validation boundaries

Phone content is held in bounded memory only. It is not added to activity logs,
trust files, command output, backups or a persistent notification archive.
Requests expire, native jobs dispatch once, and permissions are rechecked before
native execution and before response delivery. Side effects are never retried
automatically. A timeout may follow an action already submitted to Android; check
the phone before resending an SMS or dialing again. Android stores random action
IDs briefly for duplicate protection, never recipients or message bodies.

Generated Rust/Flutter tests cover grant separation, revocation, no content in
status/history, compose confirmation, banner privacy and native host lifecycle.
No automated test sends a real SMS, places/answers a carrier call, changes a default
phone app, or reads personal messages/call logs. Native call/SMS traffic and iOS/
Windows runtime validation require explicit device testing and are not claimed.

Platform references: [Android notification listener](https://developer.android.com/reference/android/service/notification/NotificationListenerService),
[SMS and call-log restrictions](https://developer.android.com/reference/android/Manifest.permission),
[default dialer requirements](https://developer.android.com/reference/android/telecom/InCallService),
[call-audio capture restrictions](https://developer.android.com/media/platform/sharing-audio-input),
[Apple SMS composer](https://developer.apple.com/documentation/messageui/mfmessagecomposeviewcontroller),
[Apple accessory notification forwarding](https://developer.apple.com/documentation/accessorynotifications).

## Contacts

Open **Phone companion → Contacts** for a paired Android/iPhone source. On Android,
allow **Settings → Phone integration → Allow reading contacts**, enable integration,
and grant **Share contacts** to the viewer in Device settings. iOS source preview
adds **Allow contacts sharing**; its OS contact picker/limited access determines
which contacts Narad can read. iOS still requires macOS compilation/device QA.

The live list refreshes every ten seconds while visible, with bounded twenty-contact
pages. It includes names, up to eight phone numbers and eight emails; photos, notes,
postal addresses, groups and account credentials are excluded. Revocation/errors and
backgrounding clear displayed content. The address book is not persisted by Narad.

**Contact actions → Save contact** opens the system contact editor on Android/iOS
for review and explicit Save; desktop exports an escaped UTF-8 vCard to a location
chosen by the user. SMS/call actions open the existing confirmation dialogs, using
the contact's first phone number. This provides live access and deliberate copying,
not automatic two-way address-book merging, deletion propagation or conflict resolution.
Android and iOS can exchange their permitted contacts in either direction; desktop
can view/export phone contacts but does not yet publish a desktop address book.

References: [Android contact insertion](https://developer.android.com/reference/android/provider/ContactsContract.Intents.Insert),
[Apple contact access](https://developer.apple.com/documentation/contacts/accessing-the-contact-store).

Mirrored notifications include a compact source app icon on Android, Linux and
Windows, and in Narad's notification list. App logos use a 32 × 32 PNG; a
notification's small icon is used if its app logo cannot be resolved. Icons share
the existing notification permission and payload budget. Text and action buttons
have priority; missing or invalid icons fall back to the normal Narad appearance.
Windows keeps only the active notification icons in its application cache and
removes them on withdrawal or the next icon-cache startup.

Mirrored notification titles use **device · app name**, with the original title
and full message below, followed by the available action buttons. Android and
Windows retain Narad's system app attribution, which is not a per-notification
content field. On Linux, the notification sender heading
is **device · app name** beside the Narad icon, with message content below.

## Desktop notification sources

Enable **Settings → Share desktop notifications** on a Linux desktop or a
Windows MSIX installation. On that desktop, grant each recipient **Share
notifications** and, optionally, **Dismiss notifications** in its device settings.
Online Android devices and other desktops then mirror notifications automatically;
**Notifications** in a desktop device's actions opens its current alerts. An iPhone
can view alerts while Narad is open; this does not add iOS background access or
allow reading other iPhone apps' notifications.

Linux shares notifications posted through the freedesktop notification service
after sharing is enabled. It keeps up to 128 active items in memory, serves the
most recent items within the existing response budget, and clears them on opt-out.
It reconnects if the notification service restarts. Custom desktop integrations
that bypass that service are not captured. Windows shares active OS toast
notifications after the user grants notification-listener access. The ZIP build
receives notifications but needs the MSIX package to capture them.

Desktop sources support reading and dismissing alerts. They do not advertise
remote reply or arbitrary action buttons: those operations are unavailable through
the desktop listener APIs used here. Android-source actions and replies remain
supported. Each read/dismiss rechecks the source device's per-recipient permission;
revoked or expired jobs cannot execute. Narad excludes its own mirrored alerts
from capture to prevent forwarding loops. Message content stays in memory rather
than an app notification archive.
