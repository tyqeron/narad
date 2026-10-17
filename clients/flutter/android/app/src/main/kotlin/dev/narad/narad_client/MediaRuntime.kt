package dev.narad.narad_client

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/** One process-owned engine: closing the UI must not dispose authorized media sessions. */
object MediaRuntime {
    private var engine: FlutterEngine? = null
    var activity: MainActivity? = null
    var visible = false
    private var pending: MethodChannel.Result? = null
    private var permissionReturned=false
    private var requestedCamera = false
    private var requestedAudio = false
    private var requestedPlayback = false

    fun engine(context: Context): FlutterEngine {
        engine?.let { return it }
        val app = context.applicationContext
        val created = FlutterEngine(app)
        engine = created
        MethodChannel(created.dartExecutor.binaryMessenger,"dev.narad/media").setMethodCallHandler { call, result ->
            if(call.method != "prepare") { result.notImplemented(); return@setMethodCallHandler }
            val camera = call.argument<Boolean>("camera") == true
            val audio = call.argument<Boolean>("audio") == true
            val playback = call.argument<Boolean>("playback") == true
            try {
                val service = NaradService.instance ?: error("Start Narad before enabling media")
                if((camera && !service.cameraReady) || (audio && !service.audioReady)) {
                    check(visible && activity != null) { "Open Narad to enable background camera or microphone sharing" }
                    val permissions = mutableListOf<String>()
                    if(camera && app.checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) permissions.add(Manifest.permission.CAMERA)
                    if(audio && app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) permissions.add(Manifest.permission.RECORD_AUDIO)
                    if(permissions.isNotEmpty()) {
                        check(pending == null) { "A media permission request is already open" }
                        pending=result; permissionReturned=false; requestedCamera=camera; requestedAudio=audio;requestedPlayback=playback
                        activity!!.requestPermissions(permissions.toTypedArray(),1905)
                        return@setMethodCallHandler
                    }
                }
                service.prepareMedia(camera,audio,playback)
                result.success(null)
            } catch(error:Exception) { result.error("background_media",error.message,null) }
        }
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }

    fun permissionResult(context: Context) {
        permissionReturned=true
        finishPermission(context)
    }

    fun finishPermission(context: Context) {
        if(!visible || !permissionReturned)return
        val result=pending ?: return
        pending=null
        try {
            check(visible) { "Open Narad to enable background media" }
            check(!requestedCamera || context.checkSelfPermission(Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED) { "Camera permission was not granted" }
            check(!requestedAudio || context.checkSelfPermission(Manifest.permission.RECORD_AUDIO)==PackageManager.PERMISSION_GRANTED) { "Microphone permission was not granted" }
            (NaradService.instance ?: error("Narad has stopped")).prepareMedia(requestedCamera,requestedAudio,requestedPlayback)
            result.success(null)
        } catch(error:Exception) { result.error("background_media",error.message,null) }
    }

    fun serviceStopped() {
        engine?.let { MethodChannel(it.dartExecutor.binaryMessenger,"dev.narad/media").invokeMethod("stopped",null) }
    }

    fun detach(activity: MainActivity) {
        if(this.activity !== activity) return
        this.activity=null;visible=false
        pending?.error("cancelled","Media permission request cancelled",null);pending=null
    }
}
