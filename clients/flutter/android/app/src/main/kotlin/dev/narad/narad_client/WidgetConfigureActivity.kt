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

/** Launcher configuration never runs a command; the user selects a trusted target. */
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
        message=TextView(this).apply{text="Choose a paired device and command preset";textSize=20f}
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
                    message.text=if(peers.isEmpty())"Pair a device in Narad first" else "Choose the device with command presets"
                    if(peers.isNotEmpty())AlertDialog.Builder(this).setTitle("Paired devices")
                        .setItems(peers.map{it.getString("device_name")}.toTypedArray()){_,index -> loadCommands(peers[index])}.setNegativeButton("Cancel",null).show()
                }
            }catch(_:Exception){showFailure("Open Narad and check its connection service, then retry.")}
        }
    }
    private fun loadCommands(peer:JSONObject) {
        message.text="Loading permitted commands…"
        worker.execute {
            try {
                val commands=LocalBackendClient.call(this,JSONObject().put("op","list_commands").put("peer_id",peer.getString("device_id"))).getJSONArray("commands")
                runOnUiThread {
                    if(isFinishing || isDestroyed)return@runOnUiThread
                    if(commands.length()==0){message.text="Add command presets in Settings on the target device first.";return@runOnUiThread}
                    AlertDialog.Builder(this).setTitle("Choose command")
                        .setItems(Array(commands.length()){commands.getJSONObject(it).getString("label")}){_,index ->
                            val command=commands.getJSONObject(index)
                            if(!CommandWidget.valid(this,widgetId))return@setItems
                            CommandWidget.preferences(this).edit().putString("$widgetId.peer",peer.getString("device_id"))
                                .putString("$widgetId.device",peer.getString("device_name"))
                                .putString("$widgetId.command",command.getString("id"))
                                .putString("$widgetId.label",command.getString("label")).putString("$widgetId.status","Tap to run").apply()
                            CommandWidget.update(this,widgetId)
                            setResult(RESULT_OK,Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,widgetId));finish()
                        }.setNegativeButton("Cancel",null).show()
                }
            }catch(_:Exception){showFailure("Device unavailable or command permission denied. Enable command access on the target and retry.")}
        }
    }
    private fun showFailure(text:String) {runOnUiThread{if(!isFinishing && !isDestroyed)message.text=text}}
    override fun onDestroy(){worker.shutdownNow();super.onDestroy()}
}
