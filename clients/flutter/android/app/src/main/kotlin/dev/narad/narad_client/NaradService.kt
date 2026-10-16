package dev.narad.narad_client

import android.app.*
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.*
import android.net.wifi.WifiManager
import android.os.*
import org.json.JSONObject
import java.io.File
import java.net.Inet4Address
import java.net.NetworkInterface
import java.net.Socket
import java.util.concurrent.Executors

/** Owns the Rust runtime independently of an Activity or Flutter engine. */
class NaradService : Service() {
    companion object {
        var instance: NaradService? = null
            private set
        const val STOP = "dev.narad.STOP"
        const val API_PORT = 45700
        const val CONTROL_PORT = 45678
        private const val CHANNEL = "narad_connection"
        private const val NOTIFICATION = 81
        private val worker = Executors.newSingleThreadExecutor()
        @Volatile var state = "stopped"
        @Volatile var lastError: String? = null
        fun stateDirectory(context: Context) = File(context.noBackupFilesDir,"narad")
        fun deviceName(context: Context): String = context.getSharedPreferences("narad",MODE_PRIVATE)
            .getString("device_name",null) ?: "${Build.MANUFACTURER} ${Build.MODEL}".take(80)
    }
    var cameraReady=false
        private set
    var audioReady=false
        private set
    private var mediaWake:PowerManager.WakeLock?=null
    fun prepareMedia(camera:Boolean,audio:Boolean) {
        var types=ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        if(camera && Build.VERSION.SDK_INT>=30)types=types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
        if(audio && Build.VERSION.SDK_INT>=30)types=types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
        if(Build.VERSION.SDK_INT>=29)startForeground(NOTIFICATION,connectionNotification(null),types)
        cameraReady=camera;audioReady=audio
        if(camera || audio) {
            if(mediaWake==null)mediaWake=getSystemService(PowerManager::class.java).newWakeLock(PowerManager.PARTIAL_WAKE_LOCK,"narad:media").apply {setReferenceCounted(false);acquire()}
        } else {mediaWake?.release();mediaWake=null}
        getSystemService(NotificationManager::class.java).notify(NOTIFICATION,connectionNotification(null))
        lastConnectionText=""
    }
    private val phoneSyncWorker=Executors.newSingleThreadExecutor()
    private val phoneSync by lazy{PhoneNotificationSync(this)}
    @Volatile private var phoneSyncBusy=false
    private var phoneSyncTicks=0
    private var lastConnectionText=""
    private var multicast: WifiManager.MulticastLock? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var destroyed = false
    private val main = Handler(Looper.getMainLooper())
    private val platformPoll=object:Runnable {
        override fun run() {
            if(destroyed)return
            if(state=="running")worker.execute {refreshConnections();pollPlatformEvents();try{PhoneBridge.poll(this@NaradService)}catch(_:Exception){}}
            if(state=="running" && ++phoneSyncTicks%4==0 && !phoneSyncBusy){phoneSyncBusy=true;phoneSyncWorker.execute{try{phoneSync.poll()}catch(_:Exception){}finally{phoneSyncBusy=false}}}
            main.postDelayed(this,3000)
        }
    }
    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate()
        instance=this
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL,"Nearby device connection",NotificationManager.IMPORTANCE_LOW))
        val notification=connectionNotification(null)
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION,notification,ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(NOTIFICATION,notification)
        acquireMulticast()
        main.postDelayed(platformPoll,3000)
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) { stopSelf(); return START_NOT_STICKY }
        if((intent?.action==CommandWidget.REFRESH || intent?.action==CommandWidget.RUN) && state=="running")worker.execute{refreshConnections();CommandWidget.refreshAll(this)}
        if (state == "starting") return START_NOT_STICKY
        if (state == "running" && JSONObject(NativeBackend.status()).optBoolean("running")) return START_NOT_STICKY
        state="starting"; lastError=null
        worker.execute {
            try {
                val directory=stateDirectory(this).apply {mkdirs()}
                val identity=IdentityVault(directory).loadOrCreate()
                val config=JSONObject().put("state_dir",directory.absolutePath).put("api_port",API_PORT)
                    .put("name",deviceName(this)).put("port",CONTROL_PORT).put("address",lanAddress())
                    .put("no_discovery",false).put("identity",identity)
                val response=JSONObject(NativeBackend.start(config.toString()))
                check(response.optBoolean("ok")) {response.optString("error","Backend startup failed")}
                if(destroyed) {NativeBackend.stop();return@execute}
                state="running"
                refreshConnections()
                main.post {if(!destroyed && callback==null) {watchNetwork()}}
            } catch(error:Throwable) {
                state="error";lastError="Unable to start Narad: ${error.message ?: error.javaClass.simpleName}"
                main.post {stopSelf()}
            }
        }
        // A killed process resumes when the user opens Narad; never restart capture silently.
        return START_NOT_STICKY
    }
    private fun connectionNotification(names:List<String>?):Notification {
        val open=PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop=PendingIntent.getService(this,1,Intent(this,NaradService::class.java).setAction(STOP),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val title=if(names==null)"Narad · Checking connections" else DeviceWidgetModel.title(names)
        val text=if(names==null)"Connecting to your paired devices…" else DeviceWidgetModel.details(names)
        val media=if(cameraReady || audioReady) "Background sharing enabled: "+listOfNotNull(if(cameraReady)"camera" else null,if(audioReady)"microphone" else null).joinToString(", ")+". " else ""
        val expanded=if(names.isNullOrEmpty())text else "Connected devices (${names.size})\n"+names.sortedWith(String.CASE_INSENSITIVE_ORDER).joinToString("\n"){"• $it"}
        val public=Notification.Builder(this,CHANNEL).setSmallIcon(R.drawable.ic_narad_notification).setContentTitle("Narad is running")
            .setContentText(if(names==null)"Checking connections" else "${names.size} connected devices").build()
        return Notification.Builder(this,CHANNEL).setContentTitle(title).setContentText(media+text)
            .setStyle(Notification.BigTextStyle().bigText(media+expanded)).setOnlyAlertOnce(true)
            .setSmallIcon(R.drawable.ic_narad_notification).setContentIntent(open).setOngoing(true).setAutoCancel(false)
            .setCategory(Notification.CATEGORY_SERVICE).setVisibility(Notification.VISIBILITY_PRIVATE).setPublicVersion(public)
            .addAction(Notification.Action.Builder(null,"Stop Narad",stop).build()).build()
    }
    private fun refreshConnections() {
        if(destroyed || state!="running")return
        try {
            val paired=JSONObject()
            var presence=JSONObject()
            var offset=0
            do {
                val snapshot=LocalBackendClient.call(this,JSONObject().put("op","status").put("offset",offset),3000)
                val page=snapshot.getJSONObject("paired")
                for(id in page.keys())paired.put(id,page.getJSONObject(id))
                presence=snapshot.optJSONObject("presence") ?: JSONObject()
                offset+=32
            }while(snapshot.optBoolean("has_more") && offset<=512)
            val names=paired.keys().asSequence().filter{presence.optJSONObject(it)?.optBoolean("online")==true}
                .map{paired.getJSONObject(it).getJSONObject("peer").getString("device_name")}.toList()
            val text=DeviceWidgetModel.title(names)+DeviceWidgetModel.details(names)
            if(text!=lastConnectionText) {
                getSystemService(NotificationManager::class.java).notify(NOTIFICATION,connectionNotification(names))
                lastConnectionText=text
            }
            CommandWidget.updateConnections(this,paired,presence)
        }catch(_:Exception) {
            if(lastConnectionText!="checking") {
                getSystemService(NotificationManager::class.java).notify(NOTIFICATION,connectionNotification(null))
                lastConnectionText="checking"
                CommandWidget.disconnected(this)
            }
        }
    }
    private fun local(command:JSONObject):JSONObject {
        val token=File(stateDirectory(this),"api-token").readText()
        Socket("127.0.0.1",API_PORT).use { socket ->
            socket.soTimeout=3000
            socket.getOutputStream().write((JSONObject().put("token",token).put("command",command).toString()+"\n").toByteArray(Charsets.UTF_8))
            return JSONObject(socket.getInputStream().bufferedReader().readLine() ?: error("Backend disconnected"))
        }
    }
    private fun pollPlatformEvents() {
        if(destroyed || state!="running")return
        try {
            val response=local(JSONObject().put("op","platform_events"))
            if(!response.optBoolean("ok"))return
            val clipboard=response.getJSONArray("clipboard")
            if(clipboard.length()>0) {
                val text=clipboard.getJSONObject(clipboard.length()-1).getString("text")
                main.post {
                    if(!destroyed)try {getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("Narad",text))}
                    catch(_:Exception){worker.execute {try{local(JSONObject().put("op","platform_error").put("kind","clipboard.failed"))}catch(_:Exception){}}}
                }
            }
            val actions=response.getJSONArray("actions")
            for(index in 0 until actions.length()) {
                val action=actions.getJSONObject(index)
                val id=action.getString("id")
                var success=true
                var message=""
                try {
                    val validation=local(JSONObject().put("op","platform_validate").put("id",id))
                    check(validation.optBoolean("ok")){"Permission was revoked"}
                    when(action.getString("kind")) {
                        "lock" -> {
                            val manager=getSystemService(DevicePolicyManager::class.java)
                            check(manager.isAdminActive(ComponentName(this,NaradDeviceAdmin::class.java))){"Enable device administrator access in Narad device settings first"}
                            manager.lockNow();message="Device locked"
                        }
                        "unlock" -> {
                            if(!getSystemService(KeyguardManager::class.java).isDeviceLocked)message="Device is already unlocked"
                            else {
                                check(getSystemService(NotificationManager::class.java).areNotificationsEnabled()){"Enable Narad notifications to receive unlock requests"}
                                val open=PendingIntent.getActivity(this,82,Intent(this,UnlockActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
                                val notification=Notification.Builder(this,CHANNEL).setSmallIcon(R.drawable.ic_narad_notification)
                                    .setContentTitle("Unlock requested by your paired device")
                                    .setContentText("Tap to authenticate and unlock this device.")
                                    .setContentIntent(open).setAutoCancel(true).setVisibility(Notification.VISIBILITY_PRIVATE).build()
                                getSystemService(NotificationManager::class.java).notify(82,notification)
                                message="Unlock requested. Authenticate on this device."
                            }
                        }
                        else -> error("Unsupported device action")
                    }
                }catch(error:Exception){success=false;message=error.message ?: "Device action failed"}
                local(JSONObject().put("op","platform_result").put("id",id).put("success",success).put("message",message))
            }
        }catch(_:Exception){ /* Retry transient API failures without logging clipboard contents. */ }
    }
    private fun acquireMulticast() {
        val wifi=applicationContext.getSystemService(WIFI_SERVICE) as? WifiManager ?: return
        multicast=wifi.createMulticastLock("narad-discovery").apply {setReferenceCounted(false);acquire()}
    }
    private fun watchNetwork() {
        val connectivity=getSystemService(ConnectivityManager::class.java)
        val listener=object:ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network:Network) = refreshAddress()
            override fun onLost(network:Network) = refreshAddress()
            override fun onLinkPropertiesChanged(network:Network,properties:LinkProperties) = refreshAddress()
        }
        callback=listener
        connectivity.registerNetworkCallback(NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_WIFI)
            .addTransportType(NetworkCapabilities.TRANSPORT_ETHERNET).build(),listener)
        refreshAddress()
    }
    private fun refreshAddress() {
        worker.execute {
            if(destroyed || state!="running") return@execute
            try {
                val token=File(stateDirectory(this),"api-token").readText()
                Socket("127.0.0.1",API_PORT).use {socket ->
                    socket.soTimeout=3000
                    val request=JSONObject().put("token",token).put("command",JSONObject().put("op","network_address").put("address",lanAddress()))
                    socket.getOutputStream().write((request.toString()+"\n").toByteArray(Charsets.UTF_8))
                    socket.getInputStream().bufferedReader().readLine()
                }
            } catch (_: Exception) { /* A later network event or app retry will refresh the address. */ }
        }
    }
    private fun lanAddress():String {
        val connectivity=getSystemService(ConnectivityManager::class.java)
        for(network in connectivity.allNetworks) {
            val caps=connectivity.getNetworkCapabilities(network) ?: continue
            if(!caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) && !caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET)) continue
            val address=connectivity.getLinkProperties(network)?.linkAddresses?.map {it.address}
                ?.filterIsInstance<Inet4Address>()?.firstOrNull {!it.isLoopbackAddress && (it.isSiteLocalAddress || it.isLinkLocalAddress)}
            if(address!=null) return address.hostAddress!!
        }
        // Hotspot-host interfaces need not appear as the default Android network.
        try {
            val interfaces=NetworkInterface.getNetworkInterfaces()
            while(interfaces.hasMoreElements()) {
                val iface=interfaces.nextElement()
                if(!iface.isUp || !listOf("wlan","wifi","ap","eth","swlan").any {iface.name.startsWith(it)}) continue
                val address=iface.inetAddresses.toList().filterIsInstance<Inet4Address>()
                    .firstOrNull {!it.isLoopbackAddress && (it.isSiteLocalAddress || it.isLinkLocalAddress)}
                if(address!=null) return address.hostAddress!!
            }
        }catch(_:Exception){}
        return "127.0.0.1"
    }
    override fun onDestroy() {
        instance=null
        MediaRuntime.serviceStopped()
        mediaWake?.release();mediaWake=null
        cameraReady=false;audioReady=false
        phoneSyncWorker.shutdownNow();phoneSync.stop();
        destroyed=true
        main.removeCallbacks(platformPoll)
        CommandWidget.disconnected(this)
        if(state!="error")state="stopping"
        callback?.let {try {getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it)} catch(_:Exception){}}
        callback=null
        multicast?.let {if(it.isHeld)it.release()};multicast=null
        worker.execute {try {NativeBackend.stop()} finally {if(state!="error") state="stopped"}}
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
