package dev.narad.narad_client

import android.Manifest
import android.app.Activity
import android.app.role.RoleManager
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import android.telecom.TelecomManager
import android.widget.*

class PhoneSetupActivity:Activity() {
    override fun onCreate(state:Bundle?){super.onCreate(state);render()}
    override fun onResume(){super.onResume();render()}
    private fun render(){
        val layout=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(32,48,32,32)}
        layout.addView(TextView(this).apply{text="Phone integration";textSize=26f})
        layout.addView(TextView(this).apply{text="Choose what Narad can access on this phone, then allow each paired device separately in Device settings. SMS and call-log access may be restricted by your installer. Changing the default phone app is optional. Cellular audio needs a Bluetooth hands-free connection; it is not streamed over Wi-Fi."})
        layout.addView(Switch(this).apply{text="Enable phone integration";isChecked=PhoneBridge.enabled(this@PhoneSetupActivity);setOnCheckedChangeListener{_,value->getSharedPreferences("narad",MODE_PRIVATE).edit().putBoolean("phone_bridge",value).apply();if(value)startForegroundService(Intent(this@PhoneSetupActivity,NaradService::class.java))}})
        fun button(label:String,action:()->Unit){layout.addView(Button(this).apply{text=label;setOnClickListener{try{action()}catch(e:Exception){Toast.makeText(this@PhoneSetupActivity,e.message,Toast.LENGTH_LONG).show()}}})}
        button("Notification access"){startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))}
        button("Allow reading SMS"){requestPermissions(arrayOf(Manifest.permission.READ_SMS),1920)}
        button("Allow sending SMS"){requestPermissions(arrayOf(Manifest.permission.SEND_SMS),1921)}
        button("Allow call history"){requestPermissions(arrayOf(Manifest.permission.READ_CALL_LOG),1922)}
        button("Use Narad as phone app (call controls)"){
            check(getSystemService(android.app.NotificationManager::class.java).areNotificationsEnabled()){"Enable Narad notifications in Android Settings before choosing the phone role"}
            if(Build.VERSION.SDK_INT>=29){val role=getSystemService(RoleManager::class.java);check(role.isRoleAvailable(RoleManager.ROLE_DIALER)){"This device has no phone role"};startActivityForResult(role.createRequestRoleIntent(RoleManager.ROLE_DIALER),1923)}
            else startActivityForResult(Intent(TelecomManager.ACTION_CHANGE_DEFAULT_DIALER).putExtra(TelecomManager.EXTRA_CHANGE_DEFAULT_DIALER_PACKAGE_NAME,packageName),1923)
        }
        button("Allow placing calls"){requestPermissions(arrayOf(Manifest.permission.CALL_PHONE),1924)}
        val status=PhoneBridge.support(this)
        for((key,label) in listOf("notifications" to "Notification access","sms_read" to "Read SMS","sms_send" to "Send SMS","call_logs" to "Call history","call_control" to "Call controls"))
            layout.addView(TextView(this).apply{text="$label: ${if(status.optBoolean(key))"Ready" else "Not enabled"}"})
        button("Done"){finish()}
        setContentView(ScrollView(this).apply{addView(layout)})
    }
    override fun onRequestPermissionsResult(code:Int,permissions:Array<out String>,results:IntArray){super.onRequestPermissionsResult(code,permissions,results);render()}
}
