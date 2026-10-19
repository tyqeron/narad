package dev.narad.narad_client

import android.app.*
import android.content.ContentValues
import android.content.Context
import android.os.Build
import android.provider.MediaStore
import org.json.JSONObject
import java.io.File

/** Transfer polling belongs to the service so closing Flutter does not hide progress. */
object TransferNotices {
    private var initialized=false
    private val states = mutableMapOf<String,String>()
    fun update(context: Context, snapshot: JSONObject) {
        val manager=context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel("narad_transfers","File transfers",NotificationManager.IMPORTANCE_LOW))
        val prefs=context.getSharedPreferences("published_downloads",Context.MODE_PRIVATE)
        for(direction in listOf("transfers","outbound","shared_transfers")) {
            val items=snapshot.optJSONArray(direction) ?: continue
            for(index in 0 until items.length()) {
                val t=items.getJSONObject(index)
                val id=t.getString("id")
                val key="$direction:$id"
                val status=t.getString("status")
                val total=t.optLong("total",t.optLong("file_size"))
                val done=t.optLong("sent",t.optLong("received"))
                val progress=if(total==0L)0 else (done*100/total).toInt().coerceIn(0,100)
                val name=t.optString("file_name").ifBlank { File(t.optString("path")).name }
                var saveError:String?=null
                if(direction=="transfers" && status=="completed" && !prefs.getBoolean(id,false)) {
                    try {
                        publish(context,id,name)
                        check(prefs.edit().putBoolean(id,true).commit()) { "Could not record saved download" }
                    } catch(error:Exception) { saveError=error.message ?: "Could not save download" }
                }
                val signature="$status:$progress:$saveError"
                val previous=states.put(key,signature)
                if(previous==signature || (!initialized && previous==null && saveError==null && status in listOf("completed","cancelled")))continue
                val active=status !in listOf("completed","cancelled","denied")
                val body=if(saveError!=null)"Could not save to Downloads/Narad: $saveError" else if(status=="completed") { if(direction=="transfers")"Saved in Downloads/Narad" else if(direction=="shared_transfers")"Saved in shared folder" else "Transfer complete" } else "$progress% · $done / $total bytes · $status"
                val notice=Notification.Builder(context,"narad_transfers")
                    .setSmallIcon(R.drawable.ic_narad_notification)
                    .setContentTitle("${if(direction=="outbound" || t.optBoolean("outgoing"))"Sending" else "Receiving"} $name")
                    .setContentText(body).setStyle(Notification.BigTextStyle().bigText(body))
                    .setOnlyAlertOnce(true).setOngoing(active).setAutoCancel(!active)
                    .setProgress(if(active)100 else 0,progress,active && total==0L).build()
                manager.notify(key,201,notice)
            }
        }
        initialized=true
    }
    private fun publish(context:Context,id:String,name:String) {
        val source=File(NaradService.stateDirectory(context),"downloads/$id/$name")
        check(source.isFile) { "Completed download unavailable" }
        if(Build.VERSION.SDK_INT<29) {
            val folder=File(android.os.Environment.getExternalStoragePublicDirectory(android.os.Environment.DIRECTORY_DOWNLOADS),"Narad/$id")
            check(folder.isDirectory || folder.mkdirs()) { "Allow storage access to save in Downloads/Narad" }
            val target=File(folder,name)
            if(!target.exists())source.copyTo(target)
            android.media.MediaScannerConnection.scanFile(context,arrayOf(target.absolutePath),null,null)
            return
        }
        val values=ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME,name)
            put(MediaStore.MediaColumns.MIME_TYPE,"application/octet-stream")
            put(MediaStore.MediaColumns.RELATIVE_PATH,"Download/Narad")
            put(MediaStore.MediaColumns.IS_PENDING,1)
        }
        val resolver=context.contentResolver
        val uri=resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI,values) ?: error("Cannot create download")
        try {
            val output=resolver.openOutputStream(uri) ?: error("Cannot write download")
            output.use { target -> source.inputStream().use { it.copyTo(target) } }
            values.clear();values.put(MediaStore.MediaColumns.IS_PENDING,0)
            check(resolver.update(uri,values,null,null)>0) { "Cannot publish download" }
        } catch(error:Exception) { resolver.delete(uri,null,null);throw error }
    }
}
