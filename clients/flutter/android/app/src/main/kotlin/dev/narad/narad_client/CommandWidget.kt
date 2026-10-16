package dev.narad.narad_client

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.View
import android.widget.RemoteViews
import org.json.JSONObject
import java.util.UUID

/** Device action widget. The class name is retained so existing widgets migrate in place. */
class CommandWidget : AppWidgetProvider() {
    companion object {
        const val ACTION="dev.narad.WIDGET_DEVICE_ACTION"
        const val RUN="dev.narad.RUN_WIDGET_COMMAND" // legacy PendingIntents only
        const val REFRESH="dev.narad.REFRESH_DEVICE_WIDGETS"
        fun preferences(context:Context)=context.getSharedPreferences("command_widgets",Context.MODE_PRIVATE)
        fun ids(context:Context)=AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context,CommandWidget::class.java))
        fun valid(context:Context,id:Int)=AppWidgetManager.getInstance(context).getAppWidgetInfo(id)?.provider==ComponentName(context,CommandWidget::class.java)
        fun online(context:Context,id:Int):Boolean {
            val prefs=preferences(context)
            return NaradService.state=="running" && System.currentTimeMillis()-prefs.getLong("$id.checked",0)<15000 && prefs.getBoolean("$id.online",false)
        }
        fun dark(context:Context):Boolean {
            val mode=context.getSharedPreferences("narad",Context.MODE_PRIVATE).getString("theme","system")
            return mode=="dark" || (mode!="light" && (context.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK)==android.content.res.Configuration.UI_MODE_NIGHT_YES)
        }
        @Synchronized fun nonce(context:Context,id:Int):String {
            val prefs=preferences(context)
            return prefs.getString("$id.nonce",null) ?: UUID.randomUUID().toString().also{prefs.edit().putString("$id.nonce",it).commit()}
        }
        fun takeAction(context:Context,intent:Intent?):Map<String,String>? {
            if(intent?.action!=ACTION || intent.data?.scheme!="narad" || intent.data?.host!="widget")return null
            val id=intent.data?.lastPathSegment?.toIntOrNull() ?: return null
            val prefs=preferences(context)
            val token=prefs.getString("$id.nonce",null) ?: return null
            if(!valid(context,id) || token!=intent.getStringExtra("widget_nonce"))return null
            val action=intent.getStringExtra("widget_action") ?: return null
            if(!DeviceWidgetModel.known(action))return null
            val peer=prefs.getString("$id.peer",null) ?: return null
            intent.action=null // consumed once; activity recreation cannot repeat a lock/transfer
            return mapOf("peer_id" to peer,"action" to action)
        }
        fun refreshAll(context:Context) {for(id in ids(context))update(context,id)}
        fun update(context:Context,id:Int,status:String?=null) {
            if(!valid(context,id))return
            val prefs=preferences(context)
            if(status!=null)prefs.edit().putString("$id.status",status).apply()
            val configured=prefs.contains("$id.peer")
            val connected=online(context,id)
            val views=RemoteViews(context.packageName,R.layout.command_widget)
            val dark=dark(context)
            val foreground=android.graphics.Color.parseColor(if(dark)"#E0F5ED" else "#123B34")
            views.setInt(R.id.widget_root,"setBackgroundResource",if(dark)R.drawable.widget_background_dark else R.drawable.widget_background_light)
            for(view in listOf(R.id.widget_device,R.id.widget_status,R.id.widget_empty))views.setTextColor(view,foreground)
            views.setTextViewText(R.id.widget_device,prefs.getString("$id.device","Narad Devices"))
            views.setTextViewText(R.id.widget_status,if(!configured)"Choose a device to get started" else if(connected)"● Online" else "○ Offline · tap refresh to check")
            views.setTextViewText(R.id.widget_empty,"Choose a paired device using the settings icon")
            val configure=PendingIntent.getActivity(context,id,Intent(context,WidgetConfigureActivity::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,id).setData(Uri.parse("narad://configure/$id")),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            views.setOnClickPendingIntent(R.id.widget_configure,configure)
            views.setOnClickPendingIntent(R.id.widget_device,configure)
            val refresh=PendingIntent.getForegroundService(context,id,Intent(context,NaradService::class.java).setAction(REFRESH)
                .setData(Uri.parse("narad://refresh/$id")),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            views.setOnClickPendingIntent(R.id.widget_refresh,refresh)
            val adapter=Intent(context,DeviceWidgetActionsService::class.java).putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,id)
                .setData(Uri.parse("narad://adapter/$id"))
            views.setRemoteAdapter(R.id.widget_actions,adapter)
            views.setEmptyView(R.id.widget_actions,R.id.widget_empty)
            // Mutable is required only for the collection's action fill-in. Component,
            // URI and private nonce are fixed; MainActivity validates before dispatch.
            val template=Intent(context,MainActivity::class.java).setAction(ACTION).setData(Uri.parse("narad://widget/$id"))
                .putExtra("widget_nonce",nonce(context,id)).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            val mutable=if(android.os.Build.VERSION.SDK_INT>=31)PendingIntent.FLAG_MUTABLE else 0
            views.setPendingIntentTemplate(R.id.widget_actions,PendingIntent.getActivity(context,id,template,mutable or PendingIntent.FLAG_UPDATE_CURRENT))
            AppWidgetManager.getInstance(context).updateAppWidget(id,views)
            AppWidgetManager.getInstance(context).notifyAppWidgetViewDataChanged(id,R.id.widget_actions)
        }
        fun updateConnections(context:Context,paired:JSONObject,presence:JSONObject) {
            val prefs=preferences(context)
            for(id in ids(context)) {
                val peerId=prefs.getString("$id.peer",null) ?: continue
                val peer=paired.optJSONObject(peerId)?.optJSONObject("peer")
                val connected=peer!=null && presence.optJSONObject(peerId)?.optBoolean("online")==true
                val changed=prefs.getBoolean("$id.online",false)!=connected || prefs.getString("$id.device",null)!=peer?.optString("device_name")
                val edit=prefs.edit().putBoolean("$id.online",connected).putLong("$id.checked",System.currentTimeMillis())
                if(peer!=null)edit.putString("$id.device",peer.optString("device_name")).putString("$id.platform",peer.optString("platform"))
                edit.apply()
                if(changed)update(context,id)
            }
        }
        fun disconnected(context:Context) {
            val edit=preferences(context).edit()
            for(id in ids(context))edit.putBoolean("$id.online",false).putLong("$id.checked",0)
            edit.apply();refreshAll(context)
        }
    }
    override fun onReceive(context:Context,intent:Intent) {
        super.onReceive(context,intent)
        if(intent.action==Intent.ACTION_CONFIGURATION_CHANGED || intent.action==Intent.ACTION_MY_PACKAGE_REPLACED)refreshAll(context)
    }
    override fun onUpdate(context:Context,manager:AppWidgetManager,ids:IntArray) {for(id in ids)update(context,id)}
    override fun onDeleted(context:Context,ids:IntArray) {
        val edit=preferences(context).edit()
        for(id in ids)for(key in listOf("peer","command","device","platform","label","status","online","checked","nonce"))edit.remove("$id.$key")
        edit.apply()
    }
}
