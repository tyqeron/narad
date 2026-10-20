package dev.narad.narad_client

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.service.notification.StatusBarNotification
import android.util.Base64
import java.io.ByteArrayOutputStream

/** Compact icons only. Never copy avatars, attachments or full notification screenshots. */
object NotificationIcons {
    private const val SIZE=32
    private const val MAX_ENCODED=8192
    fun capture(context:Context, posted:StatusBarNotification):String? = try {
        // App logos remain legible in both light and dark notification themes.
        val drawable=try {context.packageManager.getApplicationIcon(posted.packageName)}
            catch(_:Exception){posted.notification.smallIcon?.loadDrawable(context)}
        if(drawable==null)null else {
            val bitmap=Bitmap.createBitmap(SIZE,SIZE,Bitmap.Config.ARGB_8888)
            try {
                drawable.setBounds(0,0,SIZE,SIZE);drawable.draw(Canvas(bitmap))
                val bytes=ByteArrayOutputStream()
                bitmap.compress(Bitmap.CompressFormat.PNG,100,bytes)
                Base64.encodeToString(bytes.toByteArray(),Base64.NO_WRAP).takeIf{it.length<=MAX_ENCODED}
            } finally {bitmap.recycle()}
        }
    } catch(_:Exception){null}
    fun decode(encoded:String?):Bitmap? = try {
        if(encoded.isNullOrEmpty() || encoded.length>MAX_ENCODED)null else {
            val bytes=Base64.decode(encoded,Base64.NO_WRAP)
            val bounds=BitmapFactory.Options().apply{inJustDecodeBounds=true}
            BitmapFactory.decodeByteArray(bytes,0,bytes.size,bounds)
            if(bounds.outWidth!=SIZE || bounds.outHeight!=SIZE || bounds.outMimeType!="image/png")null
            else BitmapFactory.decodeByteArray(bytes,0,bytes.size)
        }
    } catch(_:Exception){null}
}
