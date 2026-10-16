package dev.narad.narad_client

import android.app.Activity
import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.os.Bundle
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject

/** Debug-only real RemoteViews host. Never installs a widget on the user's launcher. */
class WidgetPreviewActivity:Activity() {
    private lateinit var host:AppWidgetHost
    private var widget=-1
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        val layout=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;fitsSystemWindows=true;setPadding(24,72,24,24)}
        setContentView(layout)
        layout.addView(TextView(this).apply{text="Narad device widget · debug preview";textSize=20f})
        host=AppWidgetHost(this,0x4e4152)
        host.deleteHost() // clean only this debug host's previous fixtures
        val peerId=intent.getStringExtra("peer_id")
        if(peerId==null){finish();return}
        widget=host.allocateAppWidgetId()
        val manager=AppWidgetManager.getInstance(this)
        if(!manager.bindAppWidgetIdIfAllowed(widget,ComponentName(this,CommandWidget::class.java))) {
            layout.addView(TextView(this).apply{text="Widget host binding permission required for this debug test"});return
        }
        Thread {
            try {
                val status=LocalBackendClient.call(this,JSONObject().put("op","status"))
                val peer=status.getJSONObject("paired").getJSONObject(peerId).getJSONObject("peer")
                CommandWidget.preferences(this).edit().putString("$widget.peer",peerId)
                    .putString("$widget.device",peer.getString("device_name")).putString("$widget.platform",peer.getString("platform"))
                    .putBoolean("$widget.online",true).putLong("$widget.checked",System.currentTimeMillis()).commit()
                runOnUiThread {
                    if(isFinishing || isDestroyed)return@runOnUiThread
                    val view=host.createView(this,widget,manager.getAppWidgetInfo(widget))
                    layout.addView(view,LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT,(480*resources.displayMetrics.density).toInt()))
                    host.startListening();CommandWidget.update(this,widget)
                }
            }catch(_:Exception){runOnUiThread{layout.addView(TextView(this).apply{text="Generated test peer unavailable"})}}
        }.start()
    }
    override fun onDestroy() {
        if(::host.isInitialized)host.stopListening() // explicit next launch removes fixtures after action routing
        super.onDestroy()
    }
}
