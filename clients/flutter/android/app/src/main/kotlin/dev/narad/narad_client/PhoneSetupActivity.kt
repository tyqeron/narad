package dev.narad.narad_client

import android.Manifest
import android.app.Activity
import android.app.role.RoleManager
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.telecom.TelecomManager
import android.view.Gravity
import android.view.View
import android.widget.*

class PhoneSetupActivity : Activity() {
    private var rendered = false

    override fun onCreate(state: Bundle?) {
        super.onCreate(state)
        render()
    }

    override fun onResume() {
        super.onResume()
        if (rendered) render()
    }

    private fun dp(value: Int) = (value * resources.displayMetrics.density).toInt()

    private fun render() {
        val dark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        val ink = if (dark) Color.rgb(231, 239, 234) else Color.rgb(30, 54, 48)
        val muted = if (dark) Color.rgb(179, 194, 185) else Color.rgb(95, 111, 104)
        val accent = if (dark) Color.rgb(142, 206, 183) else Color.rgb(40, 100, 88)
        val surface = if (dark) Color.rgb(27, 38, 33) else Color.rgb(247, 249, 247)
        val cardColor = if (dark) Color.rgb(39, 52, 46) else Color.WHITE
        val page = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(dp(20), dp(12), dp(20), dp(28))
            setBackgroundColor(surface)
        }
        val scroll = ScrollView(this).apply { addView(page) }
        setPhoneContent(scroll)

        page.addView(TextView(this).apply {
            text = "‹   Settings"
            textSize = 16f
            setTextColor(accent)
            setPadding(0, dp(8), 0, dp(18))
            setOnClickListener { finish() }
        })
        page.addView(TextView(this).apply {
            text = "Phone integration"
            textSize = 30f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(ink)
        })
        page.addView(TextView(this).apply {
            text = "Connect your phone’s useful features to paired Narad devices. You choose what is shared, and per-device access stays controlled in Device settings."
            textSize = 15f
            setTextColor(muted)
            setPadding(0, dp(8), 0, dp(18))
        })

        val enabled = PhoneBridge.enabled(this)
        val hero = card()
        hero.background = GradientDrawable().apply { setColor(cardColor); cornerRadius = dp(20).toFloat() }
        hero.addView(TextView(this).apply {
            text = if (enabled) "Phone integration is on" else "Phone integration is off"
            textSize = 19f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(ink)
        })
        hero.addView(TextView(this).apply {
            text = if (enabled) "Narad can sync the phone features you have allowed." else "Turn it on to make approved phone features available to your paired devices."
            textSize = 14f
            setTextColor(muted)
            setPadding(0, dp(5), 0, dp(10))
        })
        hero.addView(Switch(this).apply {
            text = "Enable phone integration"
            textSize = 15f
            isChecked = enabled
            setOnCheckedChangeListener { _, value ->
                getSharedPreferences("narad", MODE_PRIVATE).edit().putBoolean("phone_bridge", value).apply()
                if (value && Build.VERSION.SDK_INT >= 26) startForegroundService(Intent(this@PhoneSetupActivity, NaradService::class.java))
                render()
            }
        })
        page.addView(hero)

        val support = PhoneBridge.support(this)
        val permissions = section("PHONE DATA", "Choose which phone information Narad may access.")
        permissions.background = GradientDrawable().apply { setColor(cardColor); cornerRadius = dp(20).toFloat() }
        addPermission(permissions, "Contacts", support.optBoolean("contacts"), "contacts.read") { requestPermissions(arrayOf(Manifest.permission.READ_CONTACTS), 1925) }
        addPermission(permissions, "Notifications", support.optBoolean("notifications"), "notification access") { startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)) }
        addPermission(permissions, "Read SMS", support.optBoolean("sms_read"), "sms.read") { requestPermissions(arrayOf(Manifest.permission.READ_SMS), 1920) }
        addPermission(permissions, "Send SMS", support.optBoolean("sms_send"), "sms.send") { requestPermissions(arrayOf(Manifest.permission.SEND_SMS), 1921) }
        addPermission(permissions, "Call history", support.optBoolean("call_logs"), "calls.read") { requestPermissions(arrayOf(Manifest.permission.READ_CALL_LOG), 1922) }
        page.addView(permissions)

        val calls = section("CALL CONTROLS", "Optional Android phone role for call controls. You can keep your current phone app.")
        calls.background = GradientDrawable().apply { setColor(cardColor); cornerRadius = dp(20).toFloat() }
        addPermission(calls, "Place calls", support.optBoolean("call_permission"), "calls.control") { requestPermissions(arrayOf(Manifest.permission.CALL_PHONE), 1924) }
        val roleButton = Button(this).apply {
            text = "Choose Narad as phone app"
            isAllCaps = false
            setOnClickListener {
                try {
                    check(getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled()) { "Enable Narad notifications in Android Settings before choosing the phone role" }
                    if (Build.VERSION.SDK_INT >= 29) {
                        val role = getSystemService(RoleManager::class.java)
                        check(role.isRoleAvailable(RoleManager.ROLE_DIALER)) { "This device has no phone role" }
                        startActivityForResult(role.createRequestRoleIntent(RoleManager.ROLE_DIALER), 1923)
                    } else startActivityForResult(Intent(TelecomManager.ACTION_CHANGE_DEFAULT_DIALER).putExtra(TelecomManager.EXTRA_CHANGE_DEFAULT_DIALER_PACKAGE_NAME, packageName), 1923)
                } catch (e: Exception) { Toast.makeText(this@PhoneSetupActivity, e.message, Toast.LENGTH_LONG).show() }
            }
        }
        calls.addView(roleButton)
        page.addView(calls)

        page.addView(TextView(this).apply {
            text = "Phone data permissions are controlled by Android. A paired device also needs its own grant in Device settings. SMS and call-log access can be restricted by the app installer. Call audio remains on the phone’s current audio route; Narad desktop call audio is not available yet."
            textSize = 13f
            setTextColor(muted)
            setPadding(dp(4), dp(8), dp(4), dp(12))
        })
        page.addView(Button(this).apply {
            text = "Done"
            isAllCaps = false
            setOnClickListener { finish() }
        })
        rendered = true
    }

    private fun card(): LinearLayout = LinearLayout(this).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(dp(16), dp(14), dp(16), dp(14))
        val dark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
        background = GradientDrawable().apply { setColor(if (dark) Color.rgb(39, 52, 46) else Color.WHITE); cornerRadius = dp(20).toFloat() }
        layoutParams = LinearLayout.LayoutParams(-1, -2).apply { bottomMargin = dp(12) }
    }

    private fun section(title: String, subtitle: String): LinearLayout {
        val box = card()
        box.addView(TextView(this).apply {
            text = title
            textSize = 12f
            setTypeface(typeface, Typeface.BOLD)
            setTextColor(if (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES) Color.rgb(142, 206, 183) else Color.rgb(40, 100, 88))
            letterSpacing = .08f
        })
        box.addView(TextView(this).apply {
            text = subtitle
            textSize = 14f
            setTextColor(if (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES) Color.rgb(179, 194, 185) else Color.rgb(95, 111, 104))
            setPadding(0, dp(5), 0, dp(6))
        })
        return box
    }

    private fun addPermission(parent: LinearLayout, label: String, ready: Boolean, purpose: String, action: () -> Unit) {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(0, dp(7), 0, dp(7))
        }
        val text = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; layoutParams = LinearLayout.LayoutParams(0, -2, 1f) }
        text.addView(TextView(this).apply { this.text = label; textSize = 15f; setTextColor(if (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES) Color.rgb(231, 239, 234) else Color.rgb(30, 54, 48)) })
        text.addView(TextView(this).apply {
            this.text = if (ready) "Ready · $purpose" else "Not allowed · tap to set up"
            textSize = 12f
            val dark = resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
            setTextColor(if (ready) { if (dark) Color.rgb(142, 206, 183) else Color.rgb(40, 100, 88) } else { if (dark) Color.rgb(179, 194, 185) else Color.rgb(95, 111, 104) })
        })
        row.addView(text)
        row.addView(Button(this).apply {
            this.text = if (ready) "Manage" else "Allow"
            isAllCaps = false
            setOnClickListener { try {
                if (ready) startActivity(Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:$packageName"))) else action()
            } catch (e: Exception) { Toast.makeText(this@PhoneSetupActivity, e.message, Toast.LENGTH_LONG).show() } }
        })
        parent.addView(row)
        parent.addView(View(this).apply { setBackgroundColor(if (resources.configuration.uiMode and Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES) Color.rgb(58, 72, 64) else Color.rgb(232, 237, 233)); layoutParams = LinearLayout.LayoutParams(-1, dp(1)) })
    }

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, results: IntArray) {
        super.onRequestPermissionsResult(code, permissions, results)
        render()
    }
}
