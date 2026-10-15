package dev.narad.narad_client

import android.app.*
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
    private var multicast: WifiManager.MulticastLock? = null
    private var callback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var destroyed = false
    private val main = Handler(Looper.getMainLooper())
    override fun onBind(intent: Intent?) = null
    override fun onCreate() {
        super.onCreate()
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL,"Nearby device connection",NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this,0,Intent(this,MainActivity::class.java),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val stop = PendingIntent.getService(this,1,Intent(this,NaradService::class.java).setAction(STOP),PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        val notification = Notification.Builder(this,CHANNEL).setContentTitle("Narad is available nearby")
            .setContentText("Pairing and incoming transfers require your approval.")
            .setSmallIcon(android.R.drawable.stat_sys_upload_done).setContentIntent(open).setOngoing(true)
            .addAction(Notification.Action.Builder(null,"Stop Narad",stop).build()).build()
        if (Build.VERSION.SDK_INT >= 29) startForeground(NOTIFICATION,notification,ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
        else startForeground(NOTIFICATION,notification)
        acquireMulticast()
    }
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == STOP) { stopSelf(); return START_NOT_STICKY }
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
                main.post {if(!destroyed && callback==null) {watchNetwork()}}
            } catch(error:Throwable) {
                state="error";lastError="Unable to start Narad: ${error.message ?: error.javaClass.simpleName}"
                main.post {stopSelf()}
            }
        }
        // A killed process resumes when the user opens Narad; never restart capture silently.
        return START_NOT_STICKY
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
        destroyed=true
        if(state!="error")state="stopping"
        callback?.let {try {getSystemService(ConnectivityManager::class.java).unregisterNetworkCallback(it)} catch(_:Exception){}}
        callback=null
        multicast?.let {if(it.isHeld)it.release()};multicast=null
        worker.execute {try {NativeBackend.stop()} finally {if(state!="error") state="stopped"}}
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }
}
