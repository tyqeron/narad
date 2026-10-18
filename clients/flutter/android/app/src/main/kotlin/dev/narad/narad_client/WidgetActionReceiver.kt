package dev.narad.narad_client

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.ClipboardManager
import android.graphics.Color
import android.os.Bundle
import android.view.View
import android.widget.Toast
import org.json.JSONObject
import java.util.concurrent.Executors

/** Validates each launcher click and runs actions that need no picker in the background. */
class WidgetActionReceiver:BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {
        val action=CommandWidget.takeAction(context,intent) ?: return
        val peer=action["peer_id"] ?: return
        val kind=action["action"] ?: return
        try {context.startForegroundService(Intent(context,NaradService::class.java))}catch(_:Exception){}
        if(kind=="clipboard") {
            val widget=intent.data?.lastPathSegment?.toIntOrNull() ?: return
            val prefs=CommandWidget.preferences(context)
            val handoff=Intent(context,WidgetClipboardActivity::class.java).setAction(CommandWidget.ACTION)
                .setData(android.net.Uri.parse("narad://widget/"+widget))
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,widget)
                .putExtra("widget_nonce",prefs.getString("$widget.nonce",null))
                .putExtra("widget_action","clipboard")
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
            try {context.startActivity(handoff)}catch(_:Exception){Toast.makeText(context,"Could not read the current clipboard",Toast.LENGTH_SHORT).show()}
            return
        }
        if(!DeviceWidgetModel.runsInBackground(kind)) {
            val widget=intent.data?.lastPathSegment?.toIntOrNull() ?: return
            val nonce=CommandWidget.preferences(context).getString("$widget.nonce",null) ?: return
            val open=Intent(context,MainActivity::class.java).setAction(CommandWidget.ACTION)
                .setData(android.net.Uri.parse("narad://widget/"+widget))
                .putExtra("widget_nonce",nonce).putExtra("widget_action",kind)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            try {context.startActivity(open)}catch(_:Exception){Toast.makeText(context,"Open Narad and retry this action",Toast.LENGTH_SHORT).show()}
            return
        }
        val pending=goAsync()
        executor.execute {
            try {
                LocalBackendClient.awaitReady(context)
                var offset=0;var online=false;var paired=false;var more=false
                do {
                    val snapshot=LocalBackendClient.call(context,JSONObject().put("op","status").put("offset",offset))
                    val devices=snapshot.getJSONObject("paired")
                    if(devices.has(peer))paired=true
                    online=online || snapshot.optJSONObject("presence")?.optJSONObject(peer)?.optBoolean("online")==true
                    more=snapshot.optBoolean("has_more")
                    offset+=32
                    if(paired)break
                }while(more && offset<=512)
                check(paired){"This device is no longer paired. Reconfigure the widget."}
                check(online){"This device is offline. Open Narad on both devices and retry."}
                var result=LocalBackendClient.call(context,JSONObject().put("op","device_action").put("peer_id",peer).put("kind",kind))
                val id=result.optString("id","")
                if(id.isNotEmpty()) {
                    for(attempt in 0 until 10) {
                        if(result.optString("status") !in listOf("pending","dispatched"))break
                        Thread.sleep(1600)
                        result=LocalBackendClient.call(context,JSONObject().put("op","device_action_status").put("peer_id",peer).put("id",id))
                    }
                    check(result.optString("status") !in listOf("pending","dispatched")){"The device has not responded yet"}
                    check(result.optString("status")!="failed"){result.optString("message","Device action failed")}
                } else check(result.optInt("exit_code",0)==0){result.optString("stderr","Device action failed")}
                val detail=result.optString("message").takeIf{it.isNotBlank()} ?: (kind.replaceFirstChar{it.uppercase()}+" request sent")
                show(context,detail)
            }catch(error:Exception){show(context,error.message ?: "Device action failed")}
            finally{pending.finish()}
        }
    }
    private fun show(context:Context,message:String){android.os.Handler(context.mainLooper).post{Toast.makeText(context,message,Toast.LENGTH_LONG).show()}}
    companion object {private val executor=Executors.newCachedThreadPool()}
}

/**
 * Short, transparent foreground handoff: Android permits clipboard reads while
 * this user-triggered Activity owns window focus. It shows no editor or clipboard text.
 */
class WidgetClipboardActivity:Activity() {
    private var started=false
    private val worker=Executors.newSingleThreadExecutor()
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        window.setBackgroundDrawableResource(android.R.color.transparent)
        window.setDimAmount(0f)
        window.setWindowAnimations(0)
        setContentView(View(this).apply{setBackgroundColor(Color.TRANSPARENT)})
        try{startForegroundService(Intent(this,NaradService::class.java))}catch(_:Exception){}
        if(CommandWidget.takeAction(this,intent)?.get("action")!="clipboard"){finish();return}
    }
    override fun onWindowFocusChanged(hasFocus:Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if(!hasFocus || started)return
        started=true
        window.decorView.postDelayed({
            if(isFinishing)return@postDelayed
            val clip=try{getSystemService(ClipboardManager::class.java).primaryClip?.getItemAt(0)?.text?.toString()}catch(_:Exception){null}
            if(clip.isNullOrEmpty()){feedback("No text is available in the current clipboard");finish();return@postDelayed}
            if(clip.toByteArray(Charsets.UTF_8).size>16384){feedback("Clipboard text is larger than Narad's 16 KB limit");finish();return@postDelayed}
            val peer=CommandWidget.preferences(this).getString("$widgetId.peer",null)
            if(peer.isNullOrBlank()){feedback("Choose a device for this widget first");finish();return@postDelayed}
            worker.execute {
                try {
                    LocalBackendClient.awaitReady(this)
                    LocalBackendClient.call(this,JSONObject().put("op","send_clipboard").put("peer_id",peer).put("text",clip))
                    feedback("Clipboard sent for approval")
                }catch(error:Exception){feedback(error.message ?: "Clipboard could not be sent")}
                finally{runOnUiThread{finish()}}
            }
        },120)
    }
    private val widgetId get()=intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,AppWidgetManager.INVALID_APPWIDGET_ID)
    private fun feedback(message:String){runOnUiThread{Toast.makeText(this,message,Toast.LENGTH_LONG).show()}}
    override fun onDestroy(){worker.shutdownNow();super.onDestroy()}
}
