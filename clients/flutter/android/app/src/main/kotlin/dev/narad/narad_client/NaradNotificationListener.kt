package dev.narad.narad_client

import android.app.KeyguardManager
import android.app.PendingIntent
import android.os.Build
import java.util.UUID
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
        private data class Button(val key:String,val intent:PendingIntent,val title:String)
        private val buttons=mutableMapOf<String,Button>()
        /** Preserve the text Android exposes, including inbox and conversation styles. */
        fun content(notification:Notification):String {
            val e=notification.extras
            val big=e.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()
            if(!big.isNullOrBlank())return big.take(12000)
            val messages=Notification.MessagingStyle.Message.getMessagesFromBundleArray(e.getParcelableArray(Notification.EXTRA_MESSAGES))
            if(messages.isNotEmpty())return messages.joinToString("\n"){m ->
                val sender=if(Build.VERSION.SDK_INT>=28)m.senderPerson?.name else m.sender
                listOfNotNull(sender?.toString()?.takeIf{it.isNotBlank()},m.text?.toString()).joinToString(": ")
            }.take(12000)
            val lines=e.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
            return (lines?.joinToString("\n") ?: e.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()).take(12000)
        }
        @Synchronized fun list():JSONArray {
            val s=service();val result=JSONArray()
            val active=s.activeNotifications.orEmpty()
            buttons.entries.removeAll{(_,b)->active.none{n->n.key==b.key && n.notification.actions.orEmpty().any{it.actionIntent==b.intent && it.title.toString().take(120)==b.title}}}
            for(n in active.sortedByDescending{it.postTime}) {
                if(n.packageName==s.packageName || n.notification.flags and Notification.FLAG_GROUP_SUMMARY!=0)continue
                val notification=n.notification
                val app=try{s.packageManager.getApplicationLabel(s.packageManager.getApplicationInfo(n.packageName,0)).toString().take(120)}catch(_:Exception){n.packageName}
                val actions=JSONArray()
                for(a in notification.actions.orEmpty()) {
                    if(a.remoteInputs?.isNotEmpty()==true || a.actionIntent==null)continue
                    val title=a.title?.toString()?.take(120).orEmpty();if(title.isBlank())continue
                    val token=buttons.entries.firstOrNull{it.value==Button(n.key,a.actionIntent,title)}?.key ?: UUID.randomUUID().toString().also{buttons[it]=Button(n.key,a.actionIntent,title)}
                    if(actions.length()<4)actions.put(JSONObject().put("id",token).put("title",title))
                }
                val item=JSONObject().put("key",n.key).put("app",app).put("title",notification.extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.take(1000) ?: "")
                    .put("text",content(notification))
                    .put("time",n.postTime).put("reply",notification.actions?.any{a->a.remoteInputs?.any{it.allowFreeFormInput}==true}==true)
                    .put("dismissible",n.isClearable).put("actions",actions)
                if(result.length()>=30 || result.toString().toByteArray().size+item.toString().toByteArray().size>38000)break
                result.put(item)
            };return result
        }
        @Synchronized fun perform(c:Context,key:String,token:String) {
            val s=service();val button=buttons[token] ?: error("Notification action expired")
            check(button.key==key){"Notification action mismatch"}
            val n=s.activeNotifications.firstOrNull{it.key==key && it.packageName!=s.packageName} ?: error("Notification expired")
            val action=n.notification.actions.orEmpty().firstOrNull{it.actionIntent==button.intent && it.title.toString().take(120)==button.title && it.remoteInputs.isNullOrEmpty()} ?: error("Notification action changed")
            if(Build.VERSION.SDK_INT>=31 && action.isAuthenticationRequired)check(!c.getSystemService(KeyguardManager::class.java).isDeviceLocked){"Unlock the phone to use this action"}
            buttons.remove(token) // An ambiguous send must never be retried automatically.
            action.actionIntent.send()
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
    override fun onListenerDisconnected(){if(current===this){current=null;synchronized(buttons){buttons.clear()}}}
    override fun onDestroy(){if(current===this){current=null;synchronized(buttons){buttons.clear()}};super.onDestroy()}
}
