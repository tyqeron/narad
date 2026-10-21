package dev.narad.narad_client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.widget.Toast
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.Executors

/** Ephemeral targets: stale buttons fail closed after reconnect, revocation or process exit. */
class PhoneNotificationAction:BroadcastReceiver() {
    override fun onReceive(context:Context,intent:Intent) {
        val token=intent.data?.lastPathSegment ?: return
        val target=targets[token] ?: return
        val text=RemoteInput.getResultsFromIntent(intent)?.getCharSequence("reply")?.toString()
        if(target.kind=="notification_reply" && (text.isNullOrBlank() || text.length>2000))return
        val pending=goAsync()
        executor.execute {
            try {
                if(targets.remove(token)!=target)return@execute
                val status=LocalBackendClient.call(context,JSONObject().put("op","status"))
                check(status.getJSONObject("paired").has(target.peer) && status.getJSONObject("presence").optJSONObject(target.peer)?.optBoolean("online")==true){"Device is offline"}
                val args=JSONObject().put("key",target.key)
                if(text!=null)args.put("text",text)
                if(target.action!=null)args.put("action",target.action)
                // The source rechecks pairing, capability grants and the live action before executing.
                LocalBackendClient.call(context,JSONObject().put("op","phone_request").put("peer_id",target.peer).put("kind",target.kind).put("args",args))
                if(target.kind=="notification_dismiss") {
                    context.getSystemService(NotificationManager::class.java).cancel(target.notification)
                    clear(target.notification)
                }
            } catch(_:Exception) {
                android.os.Handler(context.mainLooper).post{Toast.makeText(context,"Notification action unavailable. Check the device and its permissions.",Toast.LENGTH_LONG).show()}
            } finally {pending.finish()}
        }
    }
    companion object {
        data class Target(val peer:String,val key:String,val kind:String,val action:String?,val notification:Int)
        val targets=java.util.concurrent.ConcurrentHashMap<String,Target>()
        private val executor=Executors.newSingleThreadExecutor()
        fun clear(id:Int){targets.entries.removeAll{it.value.notification==id}}
        fun button(c:Context,id:Int,peer:String,key:String,kind:String,label:String,action:String?=null):Notification.Action {
            val token=UUID.randomUUID().toString();targets[token]=Target(peer,key,kind,action,id)
            val intent=Intent(c,PhoneNotificationAction::class.java).setData(Uri.parse("narad-notification://action/$token"))
            val reply=kind=="notification_reply"
            val flags=if(reply && Build.VERSION.SDK_INT>=31)PendingIntent.FLAG_MUTABLE else if(reply)0 else PendingIntent.FLAG_IMMUTABLE
            val pending=PendingIntent.getBroadcast(c,0,intent,flags or PendingIntent.FLAG_UPDATE_CURRENT)
            val builder=Notification.Action.Builder(null,label,pending)
            if(reply)builder.addRemoteInput(RemoteInput.Builder("reply").setLabel("Reply").build())
            return builder.build()
        }
    }
}

/** Background viewer for explicitly granted phone data. No persistent content archive. */
class PhoneNotificationSync(private val context:Context) {
    private val seen=mutableMapOf<String,Map<String,String>>()
    private val posted=mutableMapOf<String,Int>()
    @Volatile private var stopped=false
    private var nextId=10000
    private val manager get()=context.getSystemService(NotificationManager::class.java)
    private fun remove(key:String){posted.remove(key)?.let{manager.cancel(it);PhoneNotificationAction.clear(it)}}
    @Synchronized fun stop(){stopped=true;posted.keys.toList().forEach{remove(it)};seen.clear()}
    fun poll() {
        val status=LocalBackendClient.call(context,JSONObject().put("op","status"))
        val paired=status.getJSONObject("paired");val presence=status.getJSONObject("presence")
        val online=paired.keys().asSequence().filter{presence.optJSONObject(it)?.optBoolean("online")==true}.toSet()
        synchronized(this){posted.keys.toList().filter{it.substringBefore('/') !in online}.forEach{remove(it)};seen.keys.removeAll{it.substringBefore('/') !in online}}
        manager.createNotificationChannel(NotificationChannel("narad_phone_notifications","Synced device notifications",NotificationManager.IMPORTANCE_DEFAULT))
        for(peer in online)for(kind in if(paired.getJSONObject(peer).getJSONObject("peer").optString("platform")=="android")listOf("notifications","call_state") else listOf("notifications")) {
            val bucket="$peer/$kind"
            try {
                val response=LocalBackendClient.call(context,JSONObject().put("op","phone_request").put("peer_id",peer).put("kind",kind).put("args",JSONObject()))
                if(stopped || NaradService.state!="running")return
                val items=response.getJSONArray("items");val current=mutableMapOf<String,String>()
                synchronized(this) {
                    if(stopped)return
                    for(i in 0 until items.length()) {
                        val item=items.getJSONObject(i);val raw=if(kind=="notifications")item.getString("key") else "${item.getString("id")}/${item.getString("state")}"
                        val name=paired.getJSONObject(peer).getJSONObject("peer").getString("device_name")
                        val key="$bucket/$raw";val fingerprint=name+"\n"+item.toString();current[key]=fingerprint
                        if(seen[bucket]?.get(key)==fingerprint)continue
                        if(kind=="call_state" && item.optString("state")!="ringing")continue
                        val id=posted.getOrPut(key){nextId++};PhoneNotificationAction.clear(id)
                        val open=PendingIntent.getActivity(context,id,Intent(context,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                        val body=if(kind=="notifications") listOf(item.optString("title"),item.optString("text")).filter{it.isNotBlank()}.distinct().joinToString("\n") else "Open Phone in Narad for call controls"
                        val builder=Notification.Builder(context,"narad_phone_notifications").setSmallIcon(R.drawable.ic_narad_notification)
                            .setContentTitle("$name · ${if(kind=="notifications")item.optString("app") else "Incoming call"}")
                            .setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
                            .setContentIntent(open).setAutoCancel(false).setVisibility(Notification.VISIBILITY_PRIVATE).setOnlyAlertOnce(true)
                        if(kind=="notifications") {
                            builder.setOngoing(item.optBoolean("ongoing"))
                                .setProgress(item.optInt("progressMax").coerceAtLeast(0),item.optInt("progress").coerceAtLeast(0),item.optBoolean("progressIndeterminate"))
                                .setWhen(item.optLong("when",item.optLong("time",System.currentTimeMillis())))
                                .setUsesChronometer(item.optBoolean("usesChronometer"))
                                .setChronometerCountDown(item.optBoolean("chronometerCountdown"))
                            NotificationIcons.decode(item.optString("icon"))?.let{builder.setLargeIcon(it)}
                            var count=0
                            if(item.optBoolean("reply")){builder.addAction(PhoneNotificationAction.button(context,id,peer,raw,"notification_reply","Reply"));count++}
                            val actions=item.optJSONArray("actions")
                            for(j in 0 until (actions?.length() ?: 0)) {
                                if(count>=2)break
                                val a=actions!!.getJSONObject(j)
                                builder.addAction(PhoneNotificationAction.button(context,id,peer,raw,"notification_action",a.getString("title"),a.getString("id")));count++
                            }
                            if(item.optBoolean("dismissible"))builder.addAction(PhoneNotificationAction.button(context,id,peer,raw,"notification_dismiss","Dismiss"))
                        }
                        manager.notify(id,builder.build())
                    }
                    posted.keys.toList().filter{it.startsWith("$bucket/") && it !in current}.forEach{remove(it)}
                    seen[bucket]=current
                }
            }catch(_:Exception){synchronized(this){posted.keys.toList().filter{it.startsWith("$bucket/")}.forEach{remove(it)};seen.remove(bucket)}}
        }
    }
}
