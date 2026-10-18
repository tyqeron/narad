package dev.narad.narad_client

import android.app.Activity
import android.appwidget.AppWidgetManager
import android.content.Intent
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.LinearLayout
import android.widget.ImageView
import android.widget.ScrollView
import android.widget.TextView
import org.json.JSONObject
import java.util.concurrent.Executors

/** Calm, full-screen device picker shown while adding or changing a widget. */
class WidgetConfigureActivity : Activity() {
    private var widgetId=AppWidgetManager.INVALID_APPWIDGET_ID
    private val worker=Executors.newSingleThreadExecutor()
    private lateinit var list:LinearLayout
    private lateinit var hint:TextView
    private val dark get()=CommandWidget.dark(this)
    private val ink get()=if(dark)Color.rgb(231,243,238) else Color.rgb(18,59,52)
    private val muted get()=if(dark)Color.rgb(174,195,187) else Color.rgb(91,112,107)
    private val accent get()=if(dark)Color.rgb(117,211,182) else Color.rgb(21,105,89)
    private val surface get()=if(dark)Color.rgb(30,53,47) else Color.WHITE
    private val badgeSurface get()=if(dark)Color.rgb(48,78,69) else Color.rgb(230,242,237)
    override fun onCreate(savedInstanceState:Bundle?) {
        super.onCreate(savedInstanceState)
        setResult(RESULT_CANCELED)
        widgetId=intent.getIntExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,AppWidgetManager.INVALID_APPWIDGET_ID)
        if(!CommandWidget.valid(this,widgetId)){finish();return}
        val root=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(dp(24),dp(20),dp(24),dp(18));setBackgroundColor(if(dark)Color.rgb(18,34,30) else Color.rgb(246,249,247))}
        val top=LinearLayout(this).apply{gravity=Gravity.CENTER_VERTICAL}
        val logo=ImageView(this).apply{setImageResource(R.mipmap.ic_launcher);scaleType=ImageView.ScaleType.CENTER_INSIDE;setPadding(dp(5),dp(5),dp(5),dp(5));background=shape(accent,14);contentDescription="Narad"}
        top.addView(logo,LinearLayout.LayoutParams(dp(44),dp(44)))
        val heading=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(dp(13),0,0,0)}
        heading.addView(TextView(this).apply{text="Choose a device";textSize=22f;setTextColor(ink);typeface=Typeface.DEFAULT_BOLD})
        heading.addView(TextView(this).apply{text="Narad home screen widget";textSize=13f;setTextColor(muted);setPadding(0,dp(3),0,0)})
        top.addView(heading,LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1f))
        top.addView(TextView(this).apply{text="Cancel";textSize=14f;setTextColor(accent);gravity=Gravity.CENTER;setPadding(dp(10),dp(10),dp(2),dp(10));setOnClickListener{finish()}})
        root.addView(top)
        root.addView(TextView(this).apply{text="Each widget controls one paired device. Choose one below; its available actions will appear in the widget.";textSize=14f;setTextColor(muted);setLineSpacing(dp(3).toFloat(),1f);setPadding(0,dp(18),0,dp(16))})
        val section=LinearLayout(this).apply{gravity=Gravity.CENTER_VERTICAL}
        section.addView(TextView(this).apply{text="PAIRED DEVICES";textSize=11f;letterSpacing=.09f;setTextColor(muted);typeface=Typeface.DEFAULT_BOLD},LinearLayout.LayoutParams(0,ViewGroup.LayoutParams.WRAP_CONTENT,1f))
        section.addView(TextView(this).apply{text="Refresh";textSize=13f;setTextColor(accent);setPadding(dp(10),dp(8),0,dp(8));setOnClickListener{loadDevices()}})
        root.addView(section)
        hint=TextView(this).apply{text="Connecting to Narad…";textSize=14f;setTextColor(muted);setPadding(dp(4),dp(16),dp(4),dp(12))}
        root.addView(hint)
        list=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL}
        root.addView(ScrollView(this).apply{isFillViewport=true;addView(list)},LinearLayout.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT,0,1f))
        setContentView(root)
        loadDevices()
    }
    private fun dp(value:Int)=(value*resources.displayMetrics.density+.5f).toInt()
    private fun shape(color:Int,radius:Int)=GradientDrawable().apply{setColor(color);cornerRadius=dp(radius).toFloat()}
    private fun loadDevices() {
        hint.text="Checking your paired devices…";list.removeAllViews()
        try{startForegroundService(Intent(this,NaradService::class.java))}catch(_:Exception){}
        worker.execute {
            try {
                LocalBackendClient.awaitReady(this)
                val devices=mutableListOf<Pair<JSONObject,Boolean>>();var offset=0
                do {
                    val status=LocalBackendClient.call(this,JSONObject().put("op","status").put("offset",offset))
                    val paired=status.getJSONObject("paired");val presence=status.optJSONObject("presence") ?: JSONObject()
                    for(id in paired.keys())devices.add(paired.getJSONObject(id).getJSONObject("peer") to (presence.optJSONObject(id)?.optBoolean("online")==true))
                    offset+=32
                }while(status.optBoolean("has_more") && offset<=512)
                runOnUiThread {
                    if(isFinishing || isDestroyed)return@runOnUiThread
                    list.removeAllViews()
                    if(devices.isEmpty()) {
                        hint.text="No paired devices yet"
                        list.addView(TextView(this).apply{text="Pair a phone or computer in Narad, then return here to add its actions.";textSize=14f;setTextColor(muted);gravity=Gravity.CENTER;setPadding(dp(24),dp(28),dp(24),dp(28));background=shape(surface,18)},LinearLayout.LayoutParams(-1,-2).apply{topMargin=dp(8)})
                    } else {
                        hint.text=devices.size.toString()+" device"+(if(devices.size==1)"" else "s")+" · one device per widget"
                        for(device in devices.sortedBy{it.first.optString("device_name").lowercase()})list.addView(deviceCard(device.first,device.second),LinearLayout.LayoutParams(-1,-2).apply{bottomMargin=dp(10)})
                    }
                }
            }catch(_:Exception){runOnUiThread{if(!isFinishing && !isDestroyed)hint.text="Narad is starting. Tap Refresh to try again."}}
        }
    }
    private fun deviceCard(peer:JSONObject,online:Boolean):View {
        val card=LinearLayout(this).apply{orientation=LinearLayout.HORIZONTAL;gravity=Gravity.CENTER_VERTICAL;setPadding(dp(15),dp(14),dp(13),dp(14));background=shape(surface,18);setOnClickListener{selectDevice(peer)}}
        val badge=TextView(this).apply{text=when(peer.optString("platform")){"android"->"A";"ios"->"●";"windows"->"⊞";"linux"->"L";else->"N"};textSize=17f;typeface=Typeface.DEFAULT_BOLD;setTextColor(accent);gravity=Gravity.CENTER;background=shape(badgeSurface,15)}
        card.addView(badge,LinearLayout.LayoutParams(dp(48),dp(48)))
        val details=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(dp(13),0,dp(6),0)}
        details.addView(TextView(this).apply{text=peer.optString("device_name","Paired device");textSize=16f;setTextColor(ink);typeface=Typeface.DEFAULT_BOLD;maxLines=1;ellipsize=TextUtils.TruncateAt.END})
        val platform=peer.optString("platform").replaceFirstChar{it.uppercase()}
        details.addView(TextView(this).apply{text=platform+"  ·  "+(if(online)"Online" else "Offline");textSize=12f;setTextColor(if(online)accent else muted);setPadding(0,dp(4),0,0)})
        card.addView(details,LinearLayout.LayoutParams(0,-2,1f))
        card.addView(TextView(this).apply{text="›";textSize=26f;setTextColor(muted);gravity=Gravity.CENTER})
        return card
    }
    private fun selectDevice(peer:JSONObject) {
        if(!CommandWidget.valid(this,widgetId))return
        val p=CommandWidget.preferences(this)
        val saved=p.edit().putString("$widgetId.peer",peer.getString("device_id")).putString("$widgetId.device",peer.getString("device_name"))
            .putString("$widgetId.platform",peer.optString("platform")).putBoolean("$widgetId.online",false).putLong("$widgetId.checked",0)
            .remove("$widgetId.command").remove("$widgetId.label").commit()
        if(!saved)return
        CommandWidget.update(this,widgetId)
        try{startForegroundService(Intent(this,NaradService::class.java).setAction(CommandWidget.REFRESH))}catch(_:Exception){}
        setResult(RESULT_OK,Intent().putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID,widgetId));finish()
    }
    override fun onDestroy(){worker.shutdownNow();super.onDestroy()}
}
