package dev.narad.narad_client

import android.app.*
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.telecom.Call
import android.telecom.InCallService
import android.telecom.TelecomManager
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap

/** Optional default-dialer role; never requested automatically. No call audio capture. */
class NaradInCallService:InCallService() {
    companion object {
        private val callRegistry=ConcurrentHashMap<String,Call>()
        @Volatile private var current:NaradInCallService?=null
        fun isDefault(c:Context)=c.getSystemService(TelecomManager::class.java).defaultDialerPackage==c.packageName
        @Suppress("DEPRECATION") fun snapshot()=JSONArray().also { array ->for((id,call) in callRegistry)array.put(JSONObject().put("id",id)
            .put("number",call.details.handle?.schemeSpecificPart ?: "Private number").put("state",stateName(call.state)))}
        fun stateName(state:Int)=when(state){Call.STATE_RINGING->"ringing";Call.STATE_ACTIVE->"active";Call.STATE_DIALING->"dialing";Call.STATE_CONNECTING->"connecting";Call.STATE_HOLDING->"held";Call.STATE_DISCONNECTED->"ended";else->"connecting"}
        @Suppress("DEPRECATION") fun perform(kind:String,args:JSONObject) {
            val service=current ?: error("No active call service")
            if(kind=="mute"){service.setMuted(args.getBoolean("muted"));return}
            val call=callRegistry[args.getString("call_id")] ?: error("Call has ended")
            when(kind) {
                "answer"->{check(call.state==Call.STATE_RINGING){"Call is no longer ringing"};call.answer(0)}
                "reject"->{check(call.state==Call.STATE_RINGING){"Call is no longer ringing"};call.reject(false,null)}
                "hangup"->call.disconnect()
                "dtmf"->{val tone=args.getString("tone");require(tone.length==1 && tone[0] in "0123456789*#");call.playDtmfTone(tone[0]);Handler(Looper.getMainLooper()).postDelayed({call.stopDtmfTone()},180)}
                else->error("Unsupported call control")
            }
        }
        @Suppress("DEPRECATION") fun speaker(enabled:Boolean){current?.setAudioRoute(if(enabled)android.telecom.CallAudioState.ROUTE_SPEAKER else android.telecom.CallAudioState.ROUTE_EARPIECE)}
    }
    private val callbacks=ConcurrentHashMap<Call,Call.Callback>()
    override fun onCallAdded(call:Call) {
        super.onCallAdded(call);current=this;callRegistry[UUID.randomUUID().toString()]=call
        val callback=object:Call.Callback(){override fun onStateChanged(call:Call,state:Int){notifyCalls()}}
        callbacks[call]=callback;call.registerCallback(callback);notifyCalls()
    }
    override fun onCallRemoved(call:Call) {
        callbacks.remove(call)?.let{call.unregisterCallback(it)};callRegistry.entries.removeIf{it.value===call};notifyCalls();super.onCallRemoved(call)
    }
    @Suppress("DEPRECATION") private fun notifyCalls() {
        val manager=getSystemService(NotificationManager::class.java)
        if(callRegistry.isEmpty()){manager.cancel(84);return}
        manager.createNotificationChannel(NotificationChannel("narad_calls","Phone calls",NotificationManager.IMPORTANCE_HIGH))
        val ringing=callRegistry.values.any{it.state==Call.STATE_RINGING}
        val open=PendingIntent.getActivity(this,84,Intent(this,NaradCallActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification=Notification.Builder(this,"narad_calls").setSmallIcon(R.drawable.ic_narad_notification)
            .setContentTitle(if(ringing)"Incoming phone call" else "Phone call in progress").setContentText("Tap for call controls")
            .setContentIntent(open).setOnlyAlertOnce(true).setOngoing(true).setCategory(Notification.CATEGORY_CALL).setVisibility(Notification.VISIBILITY_PRIVATE)
        if(ringing)notification.setFullScreenIntent(open,true)
        manager.notify(84,notification.build())
    }
    override fun onDestroy(){for((call,callback) in callbacks)call.unregisterCallback(callback);callbacks.clear();callRegistry.clear();if(current===this)current=null;getSystemService(NotificationManager::class.java).cancel(84);super.onDestroy()}
}
