package dev.narad.narad_client

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import org.json.JSONObject

/** Background viewer for explicitly granted phone data. No persistent archive. */
class PhoneNotificationSync(private val context:Context) {
    private val seen=mutableMapOf<String,Set<String>>()
    private val posted=mutableMapOf<String,Int>()
    @Volatile private var stopped=false
    private var nextId=10000
    @Synchronized fun stop(){stopped=true;for(id in posted.values)context.getSystemService(NotificationManager::class.java).cancel(id);posted.clear();seen.clear()}
    fun poll() {
        val status=LocalBackendClient.call(context,JSONObject().put("op","status"))
        val paired=status.getJSONObject("paired");val presence=status.getJSONObject("presence")
        val online=paired.keys().asSequence().filter{presence.optJSONObject(it)?.optBoolean("online")==true && paired.getJSONObject(it).getJSONObject("peer").optString("platform")=="android"}.take(4).toSet()
        synchronized(this){for(key in posted.keys.toList())if(key.substringBefore('/') !in online){context.getSystemService(NotificationManager::class.java).cancel(posted.remove(key)!!)};seen.keys.removeAll{it.substringBefore('/') !in online}}
        for(peer in online)for(kind in listOf("notifications","call_state")) {
            val bucket="$peer/$kind"
            try {
                val response=LocalBackendClient.call(context,JSONObject().put("op","phone_request").put("peer_id",peer).put("kind",kind).put("args",JSONObject()))
                if(stopped || NaradService.state!="running")return
                val items=response.getJSONArray("items");val current=mutableSetOf<String>();val manager=context.getSystemService(NotificationManager::class.java)
                synchronized(this) {
                    if(stopped)return
                    for(i in 0 until items.length()) {
                        val item=items.getJSONObject(i);val raw=if(kind=="notifications")item.getString("key") else "${item.getString("id")}/${item.getString("state")}"
                        val key="$bucket/$raw";current.add(key)
                        if(seen[bucket]?.contains(key)==true || (seen[bucket]==null && kind=="notifications"))continue
                        if(kind=="call_state" && item.optString("state")!="ringing")continue
                        val id=posted.getOrPut(key){nextId++}
                        val open=PendingIntent.getActivity(context,id,Intent(context,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                        val name=paired.getJSONObject(peer).getJSONObject("peer").getString("device_name")
                        val notification=Notification.Builder(context,"narad_connection").setSmallIcon(R.drawable.ic_narad_notification)
                            .setContentTitle(if(kind=="notifications")"Notification on $name" else "Incoming call on $name")
                            .setContentText(if(kind=="notifications")"${item.optString("app")} · Open Narad to view" else "Open Phone in Narad for call controls")
                            .setContentIntent(open).setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE).setOnlyAlertOnce(true).build()
                        manager.notify(id,notification)
                    }
                    for(key in posted.keys.toList())if(key.startsWith("$bucket/") && key !in current)manager.cancel(posted.remove(key)!!)
                    seen[bucket]=current
                }
            }catch(_:Exception){synchronized(this){for(key in posted.keys.toList())if(key.startsWith("$bucket/"))context.getSystemService(NotificationManager::class.java).cancel(posted.remove(key)!!);seen.remove(bucket)}}
        }
    }
}
