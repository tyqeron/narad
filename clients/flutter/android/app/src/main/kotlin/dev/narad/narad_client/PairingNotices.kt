package dev.narad.narad_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.Uri
import org.json.JSONArray

/** The foreground service watches requests even when Flutter's UI is closed. */
class PairingNotices(private val context:Context) {
    private val posted=mutableMapOf<String,Int>()
    private var nextId=5000
    private var stopped=false
    @Synchronized fun update(items:JSONArray) {
        if(stopped)return
        val manager=context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("narad_pairing","Pairing requests",NotificationManager.IMPORTANCE_DEFAULT))
        val pending=mutableSetOf<String>()
        val now=System.currentTimeMillis()/1000
        for(i in 0 until items.length()) {
            val item=items.getJSONObject(i)
            if(item.optBoolean("outgoing") || item.optString("status")!="pending" || item.optLong("expires_at")<=now)continue
            val key=item.getString("id");pending.add(key)
            if(posted.containsKey(key))continue
            val id=nextId++
            val intent=Intent(context,MainActivity::class.java)
                .setData(Uri.parse("narad://pairing/$key"))
                .putExtra("narad_pairing_request",true)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            val open=PendingIntent.getActivity(context,id,intent,PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val name=item.getJSONObject("peer").optString("device_name","Nearby device")
            val notification=Notification.Builder(context,"narad_pairing")
                .setSmallIcon(R.drawable.ic_narad_notification).setContentTitle("Pairing request · $name")
                .setContentText("Open Narad to review the request and compare the verification code.")
                .setContentIntent(open).addAction(Notification.Action.Builder(null,"Review request",open).build())
                .setAutoCancel(true).setOnlyAlertOnce(true).setVisibility(Notification.VISIBILITY_PRIVATE)
                .setTimeoutAfter((item.getLong("expires_at")-now)*1000).build()
            manager.notify(id,notification);posted[key]=id
        }
        for(key in posted.keys.toList())if(key !in pending){manager.cancel(posted.remove(key)!!)}
    }
    @Synchronized fun clear() {
        stopped=true
        val manager=context.getSystemService(NotificationManager::class.java)
        posted.values.forEach{manager.cancel(it)};posted.clear()
    }
}
