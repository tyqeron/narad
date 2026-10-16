package dev.narad.narad_client

import android.Manifest
import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private var cameraResult:MethodChannel.Result?=null
    private var adminResult:MethodChannel.Result?=null
    private var exportResult:MethodChannel.Result?=null
    private var exportSource:File?=null
    private val io=Executors.newSingleThreadExecutor()
    private val main=Handler(Looper.getMainLooper())
    override fun configureFlutterEngine(flutterEngine:FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger,"dev.narad/android").setMethodCallHandler {call,result ->
            try {
                when(call.method) {
                    "importContact" -> {PhoneContacts.insert(this,org.json.JSONObject(call.arguments as Map<*,*>));result.success(null)}
                    "phoneSetup" -> {startActivity(Intent(this,PhoneSetupActivity::class.java));result.success(null)}
                    "getTheme" -> result.success(getSharedPreferences("narad",MODE_PRIVATE).getString("theme","system"))
                    "setTheme" -> {
                        val theme=call.argument<String>("theme") ?: "system"
                        require(theme in listOf("system","light","dark")){"Invalid theme"}
                        check(getSharedPreferences("narad",MODE_PRIVATE).edit().putString("theme",theme).commit()){"Theme could not be saved"}
                        CommandWidget.refreshAll(this)
                        result.success(null)
                    }
                    "ensureCameraPermission" -> {
                        if(checkSelfPermission(Manifest.permission.CAMERA)==PackageManager.PERMISSION_GRANTED)result.success(true)
                        else {check(cameraResult==null){"Camera permission request already open"};cameraResult=result;requestPermissions(arrayOf(Manifest.permission.CAMERA),1904)}
                    }
                    "ensureDeviceAdmin" -> {
                        val manager=getSystemService(DevicePolicyManager::class.java)
                        val component=ComponentName(this,NaradDeviceAdmin::class.java)
                        if(manager.isAdminActive(component))result.success(true)
                        else {
                            check(adminResult==null){"Device admin setup already open"}
                            adminResult=result
                            startActivityForResult(Intent(DevicePolicyManager.ACTION_ADD_DEVICE_ADMIN)
                                .putExtra(DevicePolicyManager.EXTRA_DEVICE_ADMIN,component)
                                .putExtra(DevicePolicyManager.EXTRA_ADD_EXPLANATION,"Allow only the paired devices you authorize to lock this device."),1903)
                        }
                    }
                    "start" -> {
                        if(Build.VERSION.SDK_INT>=33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)!=PackageManager.PERMISSION_GRANTED)
                            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS),1901)
                        startForegroundService(Intent(this,NaradService::class.java))
                        result.success(mapOf("stateDirectory" to NaradService.stateDirectory(this).absolutePath,"apiPort" to NaradService.API_PORT,"deviceName" to NaradService.deviceName(this)))
                    }
                    "takeDeviceAction" -> result.success(CommandWidget.takeAction(this,intent))
                    "status" -> result.success(mapOf("state" to NaradService.state,"error" to NaradService.lastError))
                    "stop" -> {stopService(Intent(this,NaradService::class.java));result.success(null)}
                    "setDeviceName" -> {
                        val name=call.argument<String>("name")?.trim() ?: error("Missing device name")
                        require(name.isNotEmpty() && name.toByteArray(Charsets.UTF_8).size<=128){"Use a name of 1–128 UTF-8 bytes"}
                        getSharedPreferences("narad",MODE_PRIVATE).edit().putString("device_name",name).apply();result.success(null)
                    }
                    "saveReceivedFile" -> {
                        check(exportResult==null){"A save dialog is already open"}
                        val id=call.argument<String>("id") ?: error("Missing transfer ID");UUID.fromString(id)
                        val name=call.argument<String>("name") ?: error("Missing file name")
                        require(!name.contains('/') && !name.contains('\\') && name!="." && name!="..") {"Unsafe file name"}
                        val root=File(NaradService.stateDirectory(this),"downloads/$id").canonicalFile
                        val source=File(root,name).canonicalFile
                        require(source.parentFile==root && source.isFile){"Completed download not found"}
                        exportSource=source;exportResult=result
                        startActivityForResult(Intent(Intent.ACTION_CREATE_DOCUMENT).addCategory(Intent.CATEGORY_OPENABLE)
                            .setType("application/octet-stream").putExtra(Intent.EXTRA_TITLE,name),1902)
                    }
                    else -> result.notImplemented()
                }
            }catch(error:Throwable){result.error("android_backend",error.message ?: "Android operation failed",null)}
        }
    }
    override fun onNewIntent(intent:Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
    }
    override fun onRequestPermissionsResult(requestCode:Int,permissions:Array<out String>,grantResults:IntArray) {
        super.onRequestPermissionsResult(requestCode,permissions,grantResults)
        if(requestCode==1904){val pending=cameraResult;cameraResult=null;pending?.success(grantResults.isNotEmpty() && grantResults[0]==PackageManager.PERMISSION_GRANTED)}
    }
    @Deprecated("Activity result API retained for the FlutterActivity host")
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode==1903){
            val pending=adminResult;adminResult=null
            pending?.success(getSystemService(DevicePolicyManager::class.java).isAdminActive(ComponentName(this,NaradDeviceAdmin::class.java)))
            return
        }
        if(requestCode!=1902)return
        val result=exportResult ?: return;val source=exportSource;exportResult=null;exportSource=null
        val uri=data?.data
        if(resultCode!=Activity.RESULT_OK || uri==null || source==null){result.success(false);return}
        io.execute {
            try {
                val output=contentResolver.openOutputStream(uri,"wt") ?: error("Cannot open selected destination")
                output.use {out -> source.inputStream().use {input ->input.copyTo(out,64*1024)}}
                main.post {result.success(true)}
            }catch(error:Exception){main.post {result.error("save_file",error.message,null)}}
        }
    }
    override fun onDestroy() {
        cameraResult?.error("cancelled","Camera permission cancelled",null);cameraResult=null
        adminResult?.error("cancelled","Device admin setup cancelled",null);adminResult=null
        exportResult?.error("cancelled","Save cancelled",null);exportResult=null;exportSource=null
        io.shutdown()
        super.onDestroy()
    }
}
