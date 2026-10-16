package dev.narad.narad_client

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.provider.ContactsContract as C
import org.json.JSONArray
import org.json.JSONObject

/** Live, bounded pages; no address book copy is persisted by Narad. */
object PhoneContacts {
    fun list(c:Context,args:JSONObject):JSONObject {
        val after=args.optLong("after",0);require(after>=0)
        val rows=JSONArray();var last=after;var more=false;var bytes=0
        c.contentResolver.query(C.Contacts.CONTENT_URI,arrayOf(C.Contacts._ID,C.Contacts.DISPLAY_NAME_PRIMARY),
            "${C.Contacts._ID} > ?",arrayOf(after.toString()),"${C.Contacts._ID} ASC")?.use { cursor ->
            while(cursor.moveToNext()) {
                if(rows.length()>=20){more=true;break}
                val id=cursor.getLong(0)
                val phones=JSONArray();val emails=JSONArray()
                c.contentResolver.query(C.Data.CONTENT_URI,arrayOf(C.Data.MIMETYPE,C.Data.DATA1),
                    "${C.Data.CONTACT_ID} = ? AND ${C.Data.MIMETYPE} IN (?,?)",arrayOf(id.toString(),C.CommonDataKinds.Phone.CONTENT_ITEM_TYPE,C.CommonDataKinds.Email.CONTENT_ITEM_TYPE),null)?.use { data ->
                    while(data.moveToNext()) {
                        val target=if(data.getString(0)==C.CommonDataKinds.Phone.CONTENT_ITEM_TYPE)phones else emails
                        if(target.length()<8)target.put((data.getString(1) ?: "").take(256))
                    }
                }
                val row=JSONObject().put("id",id.toString()).put("name",(cursor.getString(1) ?: "").take(256)).put("phones",phones).put("emails",emails)
                val size=row.toString().toByteArray(Charsets.UTF_8).size
                if(bytes+size>38000){more=true;break}
                rows.put(row);bytes+=size;last=id
            }
        }
        return JSONObject().put("items",rows).put("next_after",if(more)last.toString() else JSONObject.NULL)
    }
    fun insert(activity:Activity,contact:JSONObject) {
        // The system contact editor requires the user's Save; no WRITE_CONTACTS grant.
        val intent=Intent(Intent.ACTION_INSERT,C.Contacts.CONTENT_URI).setType(C.RawContacts.CONTENT_TYPE)
            .putExtra(C.Intents.Insert.NAME,contact.optString("name").take(256))
        val data=arrayListOf<android.content.ContentValues>()
        for((key,mime) in listOf("phones" to C.CommonDataKinds.Phone.CONTENT_ITEM_TYPE,"emails" to C.CommonDataKinds.Email.CONTENT_ITEM_TYPE)) {
            val values=contact.optJSONArray(key) ?: JSONArray()
            for(i in 0 until minOf(values.length(),8))data.add(android.content.ContentValues().apply{put(C.Data.MIMETYPE,mime);put(C.Data.DATA1,values.getString(i).take(256))})
        }
        intent.putParcelableArrayListExtra(C.Intents.Insert.DATA,data)
        activity.startActivity(intent)
    }
}
