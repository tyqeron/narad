package dev.narad.narad_client

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews
import org.json.JSONObject

class CommandWidget : AppWidgetProvider() {
    companion object {
        const val RUN="dev.narad.RUN_WIDGET_COMMAND"
        fun preferences(context:Context)=context.getSharedPreferences("command_widgets",Context.MODE_PRIVATE)
        fun refreshAll(context:Context) {
            for(id in AppWidgetManager.getInstance(context).getAppWidgetIds(ComponentName(context,CommandWidget::class.java)))update(context,id)
        }
        fun valid(context:Context,id:Int):Boolean = AppWidgetManager.getInstance(context).getAppWidgetInfo(id)?.provider==ComponentName(context,CommandWidget::class.java)
        fun update(context:Context,id:Int,status:String?=null) {
            if(!valid(context,id))return
            val prefs=preferences(context)
            if(status!=null)prefs.edit().putString("$id.status",status).apply()
            val configured=prefs.contains("$id.command")
            val views=RemoteViews(context.packageName,R.layout.command_widget)
            val mode=context.getSharedPreferences("narad",Context.MODE_PRIVATE).getString("theme","system")
            val dark=mode=="dark" || (mode!="light" && context.resources.configuration.uiMode and android.content.res.Configuration.UI_MODE_NIGHT_MASK==android.content.res.Configuration.UI_MODE_NIGHT_YES)
            val background=android.graphics.Color.parseColor(if(dark)"#153D35" else "#E8F4F0")
            val foreground=android.graphics.Color.parseColor(if(dark)"#E0F5ED" else "#123B34")
            views.setInt(R.id.widget_root,"setBackgroundColor",background)
            views.setTextColor(R.id.widget_device,foreground);views.setTextColor(R.id.widget_status,foreground)
            views.setTextViewText(R.id.widget_device,prefs.getString("$id.device","Narad Command"))
            views.setTextViewText(R.id.widget_run,prefs.getString("$id.label","Choose command"))
            views.setTextViewText(R.id.widget_status,prefs.getString("$id.status","Tap to run"))
            val configure=PendingIntent.getActivity(context,id,Intent(context,WidgetConfigureActivity::class.java)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,id).setData(android.net.Uri.parse("narad://configure/$id")),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            views.setOnClickPendingIntent(R.id.widget_configure,configure)
            val run=if(configured)PendingIntent.getForegroundService(context,id,Intent(context,NaradService::class.java).setAction(RUN)
                .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,id).setData(android.net.Uri.parse("narad://run/$id")),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT) else configure
            views.setOnClickPendingIntent(R.id.widget_run,run)
            AppWidgetManager.getInstance(context).updateAppWidget(id,views)
        }
        fun execute(context:Context,id:Int) {
            if(!valid(context,id))return
            val prefs=preferences(context)
            val peer=prefs.getString("$id.peer",null) ?: return
            val command=prefs.getString("$id.command",null) ?: return
            update(context,id,"Running…")
            try {
                // No cached grants or shell text: receiver authorizes the preset ID on every tap.
                val response=LocalBackendClient.call(context,JSONObject().put("op","run_command").put("peer_id",peer).put("id",command),20000)
                val code=response.optInt("exit_code",-1)
                update(context,id,if(code==0)"Completed successfully" else "Command failed · exit $code")
            }catch(_:Exception){update(context,id,"Unavailable or denied · check Narad")}
        }
    }
    override fun onReceive(context:Context,intent:Intent) {
        super.onReceive(context,intent)
        if(intent.action==Intent.ACTION_CONFIGURATION_CHANGED || intent.action==Intent.ACTION_MY_PACKAGE_REPLACED)refreshAll(context)
    }
    override fun onUpdate(context:Context,manager:AppWidgetManager,ids:IntArray) {for(id in ids)update(context,id)}
    override fun onDeleted(context:Context,ids:IntArray) {
        val edit=preferences(context).edit()
        for(id in ids)for(key in listOf("peer","command","device","label","status"))edit.remove("$id.$key")
        edit.apply()
    }
}
