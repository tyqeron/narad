package dev.narad.narad_client

import android.appwidget.AppWidgetManager
import android.content.Intent
import android.widget.RemoteViews
import android.widget.RemoteViewsService

class DeviceWidgetActionsService:RemoteViewsService() {
    override fun onGetViewFactory(intent:Intent):RemoteViewsFactory {
        val widget=intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,-1)
        return object:RemoteViewsFactory {
            private var actions=listOf<WidgetDeviceAction>()
            override fun onCreate(){onDataSetChanged()}
            override fun onDataSetChanged(){
                val prefs=CommandWidget.preferences(this@DeviceWidgetActionsService)
                actions=if(CommandWidget.valid(this@DeviceWidgetActionsService,widget) && prefs.contains("$widget.peer"))DeviceWidgetModel.actionsFor(prefs.getString("$widget.platform","") ?: "") else emptyList()
            }
            override fun getCount()=actions.size
            override fun getViewAt(position:Int):RemoteViews? {
                val action=actions.getOrNull(position) ?: return null
                val enabled=DeviceWidgetModel.enabled(action.id,CommandWidget.online(this@DeviceWidgetActionsService,widget))
                val views=RemoteViews(packageName,R.layout.widget_action_row)
                val foreground=android.graphics.Color.parseColor(if(CommandWidget.dark(this@DeviceWidgetActionsService))"#E0F5ED" else "#123B34")
                views.setTextViewText(R.id.widget_action_label,action.label)
                views.setTextColor(R.id.widget_action_label,foreground)
                views.setImageViewResource(R.id.widget_action_icon,when(action.id){
                    "file"->R.drawable.widget_file;"clipboard"->R.drawable.widget_clipboard;"audio"->R.drawable.widget_audio
                    "camera"->R.drawable.widget_camera;"browse"->R.drawable.widget_folder;"command"->R.drawable.widget_terminal
                    "lock"->R.drawable.widget_lock;"unlock"->R.drawable.widget_unlock;"settings"->R.drawable.widget_settings;else->R.drawable.widget_unpair
                })
                views.setInt(R.id.widget_action_icon,"setColorFilter",foreground)
                views.setFloat(R.id.widget_action_row,"setAlpha",if(enabled)1f else 0.38f)
                views.setBoolean(R.id.widget_action_row,"setEnabled",enabled)
                if(enabled)views.setOnClickFillInIntent(R.id.widget_action_row,Intent().putExtra("widget_action",action.id))
                return views
            }
            override fun getLoadingView():RemoteViews?=null
            override fun getViewTypeCount()=1
            override fun getItemId(position:Int)=position.toLong()
            override fun hasStableIds()=true
            override fun onDestroy(){}
        }
    }
}
