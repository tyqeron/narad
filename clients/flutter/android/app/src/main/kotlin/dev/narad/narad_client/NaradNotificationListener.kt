package dev.narad.narad_client

import android.app.Notification
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.service.notification.NotificationListenerService
import org.json.JSONArray
import org.json.JSONObject

/** No notification archive. Android's sensitive-content redaction is respected. */
class NaradNotificationListener:NotificationListenerService() {
    companion object {
        @Volatile private var current:NaradNotificationListener?=null
        fun connected()=current!=null
        private fun service()=current ?: error("Enable Narad notification access on the phone")
        fun list():JSONArray {
            val s=service();val result=JSONArray()
            for(n in s.activeNotifications.orEmpty().sortedByDescending{it.postTime}) {
                if(n.packageName==s.packageName || n.notification.flags and Notification.FLAG_GROUP_SUMMARY!=0)continue
                val notification=n.notification
                val app=try{s.packageManager.getApplicationLabel(s.packageManager.getApplicationInfo(n.packageName,0)).toString().take(120)}catch(_:Exception){n.packageName}
                val item=JSONObject().put("key",n.key).put("app",app).put("title",notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.take(200) ?: "")
                    .put("text",(notification.extras.getCharSequence(Notification.EXTRA_BIG_TEXT) ?: notification.extras.getCharSequence(Notification.EXTRA_TEXT))?.toString()?.take(1000) ?: "")
                    .put("time",n.postTime).put("reply",notification.actions?.any{a->a.remoteInputs?.any{it.allowFreeFormInput}==true}==true)
                    .put("dismissible",n.isClearable)
                if(result.length()>=30 || result.toString().toByteArray().size+item.toString().toByteArray().size>38000)break
                result.put(item)
            };return result
        }
        fun dismiss(key:String) {val s=service();check(s.activeNotifications.any{it.key==key && it.packageName!=s.packageName && it.isClearable}){"Notification expired or cannot be dismissed"};s.cancelNotification(key)}
        fun reply(c:Context,key:String,text:String) {
            val s=service();val n=s.activeNotifications.firstOrNull{it.key==key && it.packageName!=s.packageName} ?: error("Notification expired")
            val action=n.notification.actions?.firstOrNull{it.remoteInputs?.any{input->input.allowFreeFormInput}==true} ?: error("This notification does not support replies")
            val inputs=action.remoteInputs ?: error("Reply unavailable");val results=Bundle()
            for(input in inputs)if(input.allowFreeFormInput)results.putCharSequence(input.resultKey,text)
            val intent=Intent();RemoteInput.addResultsToIntent(inputs,intent,results)
            action.actionIntent.send(c,0,intent)
        }
    }
    override fun onListenerConnected(){current=this}
    override fun onListenerDisconnected(){if(current===this)current=null}
    override fun onDestroy(){if(current===this)current=null;super.onDestroy()}
}
