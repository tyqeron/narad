package dev.narad.narad_client

import android.app.Activity
import android.app.AlertDialog
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.TextView
import android.widget.Button
import org.json.JSONObject
import java.util.concurrent.Executors

/** One device per widget; configuration never executes actions or requires presets. */
class WidgetConfigureActivity : Activity() {
    private var widgetId=AppWidgetManager.INVALID_APPWIDGET_ID
    private val worker=Executors.newSingleThreadExecutor()
    private lateinit var message:TextView
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        widgetId=intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,AppWidgetManager.INVALID_APPWIDGET_ID)
        if(!CommandWidget.valid(this,widgetId)){finish();return}
        val layout=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(32,48,32,32)}
        message=TextView(this).apply{text="Choose a device for your widget";textSize=20f}
        layout.addView(message)
        layout.addView(Button(this).apply{text="Choose device";setOnClickListener{loadDevices()}})
        layout.addView(Button(this).apply{text="Cancel";setOnClickListener{finish()}})
        setContentView(layout)
        loadDevices()
    }
    private fun loadDevices() {
        message.text="Connecting to Narad…"
        startForegroundService(Intent(this,NaradService::class.java))
        worker.execute {
            try {
                LocalBackendClient.awaitReady(this)
                val peers=mutableListOf<JSONObject>()
                var offset=0
                do {
                    val status=LocalBackendClient.call(this,JSONObject().put("op","status").put("offset",offset))
                    val paired=status.getJSONObject("paired")
                    for(id in paired.keys())peers.add(paired.getJSONObject(id).getJSONObject("peer"))
                    offset+=32
                }while(status.optBoolean("has_more") && offset<=512)
                runOnUiThread {
                    if(isFinishing || isDestroyed)return@runOnUiThread
                    message.text=if(peers.isEmpty())"Pair a device in Narad first" else "Select a device to see all its actions"
                    if(peers.isNotEmpty())AlertDialog.Builder(this).setTitle("Paired devices")
                        .setItems(peers.map{it.getString("device_name")}.toTypedArray()){_,index -> selectDevice(peers[index])}.setNegativeButton("Cancel",null).show()
                }
            }catch(_:Exception){showFailure("Open Narad and check its connection service, then retry.")}
        }
    }
    private fun selectDevice(peer:JSONObject) {
        if(!CommandWidget.valid(this,widgetId))return
        CommandWidget.preferences(this).edit().putString("$widgetId.peer",peer.getString("device_id"))
            .putString("$widgetId.device",peer.getString("device_name"))
            .putString("$widgetId.platform",peer.optString("platform"))
            .putBoolean("$widgetId.online",false).putLong("$widgetId.checked",0)
            .remove("$widgetId.command").remove("$widgetId.label").commit()
        CommandWidget.update(this,widgetId)
        startForegroundService(Intent(this,NaradService::class.java).setAction(CommandWidget.REFRESH))
        setResult(RESULT_OK,Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,widgetId));finish()
    }
    private fun showFailure(text:String) {runOnUiThread{if(!isFinishing && !isDestroyed)message.text=text}}
    override fun onDestroy(){worker.shutdownNow();super.onDestroy()}
}
