package dev.narad.narad_client

import android.Manifest
import android.app.NotificationManager
import android.app.RemoteInput
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.ContactsContract
import android.provider.CallLog
import android.provider.Telephony
import android.telecom.TelecomManager
import android.telephony.SmsManager
import org.json.JSONArray
import org.json.JSONObject

/** All content is queried on demand after a backend grant check; never persisted here. */
object PhoneBridge {
    fun enabled(c:Context)=c.getSharedPreferences("narad",Context.MODE_PRIVATE).getBoolean("phone_bridge",false)
    fun granted(c:Context,p:String)=c.checkSelfPermission(p)==PackageManager.PERMISSION_GRANTED
    fun support(c:Context)=JSONObject().put("platform","android").put("enabled",enabled(c))
        .put("contacts",granted(c,Manifest.permission.READ_CONTACTS))
        .put("notifications",NaradNotificationListener.connected())
        .put("sms_read",granted(c,Manifest.permission.READ_SMS)).put("sms_send",granted(c,Manifest.permission.SEND_SMS))
        .put("call_logs",granted(c,Manifest.permission.READ_CALL_LOG)).put("call_control",NaradInCallService.isDefault(c))
        .put("cellular_audio","Bluetooth hands-free required; cellular audio is not carried over Narad Wi-Fi")
    fun poll(c:Context) {
        LocalBackendClient.call(c,JSONObject().put("op","phone_bridge_ready").put("support",support(c)))
        if(!enabled(c))return
        val jobs=LocalBackendClient.call(c,JSONObject().put("op","phone_jobs")).getJSONArray("jobs")
        for(i in 0 until jobs.length()) {
            val job=jobs.getJSONObject(i);val id=job.getString("id")
            try {
                LocalBackendClient.call(c,JSONObject().put("op","phone_validate").put("id",id))
                check(enabled(c)){"Phone integration disabled"}
                val result=try {execute(c,job.getString("kind"),job.getJSONObject("args"),id).put("ok",true)}
                    catch(e:Exception){JSONObject().put("ok",false).put("error",e.message ?: "Phone action failed")}
                LocalBackendClient.call(c,JSONObject().put("op","phone_result").put("id",id).put("result",result))
            }catch(_:Exception){/* Revoked/expired requests are dropped, never retried. */}
        }
    }
    private fun requirePermission(c:Context,p:String){check(granted(c,p)){"Allow ${p.substringAfterLast('.')} in Phone integration on the phone. Your installer may restrict SMS/call-log permissions."}}
    fun number(value:String):String {
        val number=value.filterNot{it==' ' || it=='-' || it=='(' || it==')'}
        require(Regex("\\+?[0-9]{2,20}").matches(number)){"Enter a phone number with digits and optional leading +"};return number
    }
    /** Claim before side effects. Only random IDs are kept, never recipients or content. */
    @Synchronized private fun claim(c:Context,id:String) {
        val p=c.getSharedPreferences("phone_action_ids",Context.MODE_PRIVATE)
        check(!p.contains(id)){"This action was already attempted; check the phone before retrying"}
        val edit=p.edit();val cutoff=System.currentTimeMillis()-86400000
        for((key,value) in p.all)if(value is Long && value<cutoff)edit.remove(key)
        check(p.all.size<2048){"Phone action limit reached"}
        check(edit.putLong(id,System.currentTimeMillis()).commit()){"Unable to record phone action"}
    }
    private fun execute(c:Context,kind:String,args:JSONObject,id:String):JSONObject {
        when(kind) {
            "contacts_list" -> {requirePermission(c,Manifest.permission.READ_CONTACTS);return PhoneContacts.list(c,args)}
            "notifications" -> return JSONObject().put("items",NaradNotificationListener.list())
            "notification_dismiss" -> {NaradNotificationListener.dismiss(args.getString("key"));return JSONObject()}
            "notification_reply" -> {val text=args.getString("text");require(text.isNotBlank() && text.length<=2000);claim(c,id);NaradNotificationListener.reply(c,args.getString("key"),text);return JSONObject()}
            "sms_list" -> {
                requirePermission(c,Manifest.permission.READ_SMS)
                return query(c,Telephony.Sms.CONTENT_URI,arrayOf("_id","thread_id","address","body","date","type","read"),args,true)
            }
            "calls_list" -> {
                requirePermission(c,Manifest.permission.READ_CALL_LOG)
                return query(c,CallLog.Calls.CONTENT_URI,arrayOf("_id","number","date","duration","type","name"),args,false)
            }
            "sms_send" -> {
                requirePermission(c,Manifest.permission.SEND_SMS)
                val destination=number(args.getString("number"));val body=args.getString("text")
                require(body.isNotBlank() && body.length<=1600){"SMS must contain 1–1600 characters"}
                @Suppress("DEPRECATION") val manager=if(Build.VERSION.SDK_INT>=31)c.getSystemService(SmsManager::class.java) else SmsManager.getDefault()
                val parts=manager.divideMessage(body);check(parts.size<=10){"SMS exceeds ten segments"}
                claim(c,id)
                manager.sendMultipartTextMessage(destination,null,parts,null,null)
                return JSONObject().put("status","submitted").put("message","Submitted to Android. Carrier delivery is not confirmed.")
            }
            "call_state" -> {check(NaradInCallService.isDefault(c)){"Choose Narad as the default phone app to share live calls"};return JSONObject().put("items",NaradInCallService.snapshot())}
            "dial" -> {
                check(NaradInCallService.isDefault(c)){"Choose Narad as the default phone app on Android"}
                requirePermission(c,Manifest.permission.CALL_PHONE)
                val destination=number(args.getString("number"));val telecom=c.getSystemService(TelecomManager::class.java)
                @Suppress("DEPRECATION") val emergency=if(Build.VERSION.SDK_INT>=29)c.getSystemService(android.telephony.TelephonyManager::class.java).isEmergencyNumber(destination) else android.telephony.PhoneNumberUtils.isEmergencyNumber(destination)
                check(!emergency){"Place emergency calls directly on the phone"};claim(c,id)
                telecom.placeCall(Uri.fromParts("tel",destination,null),android.os.Bundle());return JSONObject()
            }
            "answer","reject","hangup","mute","dtmf" -> {
                check(NaradInCallService.isDefault(c)){"Narad is no longer the default phone app"};claim(c,id)
                NaradInCallService.perform(kind,args);return JSONObject()
            }
            else -> error("Unsupported phone action")
        }
    }
    private fun query(c:Context,uri:Uri,columns:Array<String>,args:JSONObject,sms:Boolean):JSONObject {
        val clauses=mutableListOf<String>();val values=mutableListOf<String>()
        if(args.has("before")){val before=args.getLong("before");require(before>0);clauses.add("_id < ?");values.add(before.toString())}
        if(sms && args.has("thread_id")){val thread=args.getLong("thread_id");require(thread>0);clauses.add("thread_id = ?");values.add(thread.toString())}
        val items=JSONArray();var last:Long?=null;var more=false
        c.contentResolver.query(uri,columns,clauses.takeIf{it.isNotEmpty()}?.joinToString(" AND "),values.toTypedArray(),"_id DESC")?.use {cursor ->
            while(cursor.moveToNext()) {
                val row=JSONObject()
                for(index in columns.indices)row.put(columns[index],if(cursor.isNull(index))"" else cursor.getString(index).take(if(columns[index]=="body")1200 else 160))
                if(items.length()>=20 || items.toString().toByteArray(Charsets.UTF_8).size+row.toString().toByteArray(Charsets.UTF_8).size>38000){more=true;break}
                items.put(row);last=cursor.getLong(0)
            }
        }
        return JSONObject().put("items",items).put("next_before",if(more)last else JSONObject.NULL)
    }
}
