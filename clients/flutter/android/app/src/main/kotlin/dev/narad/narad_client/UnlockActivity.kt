package dev.narad.narad_client

import android.app.Activity
import android.app.KeyguardManager
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.TextView

/** Shows no private app content over the lock screen. Android owns authentication. */
class UnlockActivity : Activity() {
    private var requested=false
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        window.addFlags(WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON)
        setContentView(TextView(this).apply {text="Authenticate to unlock this device";gravity=Gravity.CENTER;textSize=20f})
    }
    override fun onWindowFocusChanged(hasFocus:Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if(!hasFocus || requested)return
        requested=true
        getSystemService(KeyguardManager::class.java).requestDismissKeyguard(this,object:KeyguardManager.KeyguardDismissCallback(){
            override fun onDismissSucceeded(){finish()}
            override fun onDismissCancelled(){finish()}
            override fun onDismissError(){finish()}
        })
    }
}
