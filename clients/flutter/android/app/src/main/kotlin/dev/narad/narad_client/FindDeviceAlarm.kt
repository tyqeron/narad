package dev.narad.narad_client

import android.app.*
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Handler
import android.os.Looper
import android.os.PowerManager

/** Bounded audible locator. Never changes device volume, DND, or location settings. */
object FindDeviceAlarm {
    const val STOP="dev.narad.STOP_FIND"
    private const val CHANNEL="narad_find"
    private const val NOTIFICATION=84
    private val main=Handler(Looper.getMainLooper())
    private var player:MediaPlayer?=null
    @Volatile var actionId:String?=null
        private set
    private var context:Context?=null
    private val timeout=Runnable{stop()}
    @Synchronized fun start(context:Context,id:String) {
        stop()
        val app=context.applicationContext
        val media=MediaPlayer()
        try {
            media.setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_ALARM).setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION).build())
            media.setDataSource(app,RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM) ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION))
            media.setWakeMode(app,PowerManager.PARTIAL_WAKE_LOCK)
            media.isLooping=true
            media.prepare()
            media.start()
            player=media;actionId=id;this.context=app
            val manager=app.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL,"Find device",NotificationManager.IMPORTANCE_HIGH).apply {setSound(null,null)})
            val stop=PendingIntent.getService(app,84,Intent(app,NaradService::class.java).setAction(STOP),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            val open=PendingIntent.getActivity(app,84,Intent(app,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
            manager.notify(NOTIFICATION,Notification.Builder(app,CHANNEL).setSmallIcon(R.drawable.ic_narad_notification)
                .setContentTitle("Find device · Narad").setContentText("A permitted paired device is ringing this device for up to 30 seconds.")
                .setContentIntent(open).setOngoing(true).setVisibility(Notification.VISIBILITY_PRIVATE)
                .addAction(Notification.Action.Builder(null,"Stop ringing",stop).build()).build())
            main.postDelayed(timeout,30_000)
            NaradService.instance?.mediaAlertChanged()
        } catch(error:Exception) {media.release();stop();throw error}
    }
    @Synchronized fun stop() {
        main.removeCallbacks(timeout)
        player?.release();player=null;actionId=null
        context?.getSystemService(NotificationManager::class.java)?.cancel(NOTIFICATION);context=null
        NaradService.instance?.mediaAlertChanged()
    }
}
