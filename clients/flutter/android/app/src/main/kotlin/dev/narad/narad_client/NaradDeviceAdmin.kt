package dev.narad.narad_client

import android.app.admin.DeviceAdminReceiver

/** Only force-lock is requested; no password, wipe, or reset policies. */
class NaradDeviceAdmin : DeviceAdminReceiver()
