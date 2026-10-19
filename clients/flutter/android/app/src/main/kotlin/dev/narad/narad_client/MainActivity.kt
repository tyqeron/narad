package dev.narad.narad_client

import android.Manifest
import android.app.Activity
import android.app.admin.DevicePolicyManager
import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import android.provider.OpenableColumns
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    override fun provideFlutterEngine(context:android.content.Context):FlutterEngine = MediaRuntime.engine(context)
    override fun shouldDestroyEngineWithHost() = false
    override fun onResume() {super.onResume();MediaRuntime.activity=this;MediaRuntime.visible=true;MediaRuntime.finishPermission(this)}
    override fun onPause() {MediaRuntime.visible=false;super.onPause()}

    private var sharedFolderResult:MethodChannel.Result?=null
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
                    "screenProjection" -> {
                        (NaradService.instance ?: error("Narad is not running")).screenProjection(call.argument<Boolean>("enabled") == true)
                        result.success(null)
                    }
                    "takeSharedContent" -> takeSharedContent(result)
                    "chooseSharedDirectory" -> {
                        check(sharedFolderResult==null){"Folder picker already open"}
                        sharedFolderResult=result
                        try {startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION),1906)}
                        catch(error:Exception){sharedFolderResult=null;throw error}
                    }
                    "stopFinding" -> {FindDeviceAlarm.stop();result.success(null)}
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
                        if(Build.VERSION.SDK_INT<=28 && checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE)!=PackageManager.PERMISSION_GRANTED)
                            requestPermissions(arrayOf(Manifest.permission.WRITE_EXTERNAL_STORAGE),1907)
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
    private fun takeSharedContent(result:MethodChannel.Result) {
        val incoming=intent
        if(incoming.action!=Intent.ACTION_SEND && incoming.action!=Intent.ACTION_SEND_MULTIPLE) {result.success(null);return}
        val text=incoming.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.take(10000)
        val sharedUris=(streams(incoming)+List(incoming.clipData?.itemCount ?: 0){index->incoming.clipData?.getItemAt(index)?.uri}.filterNotNull()).distinct().take(16)
        val dataUrl=incoming.data?.takeIf{it.scheme=="http" || it.scheme=="https"}?.toString()
        // Consume this share once; future shares arrive through onNewIntent.
        setIntent(Intent(this,MainActivity::class.java))
        io.execute {
            try {
                val files=mutableListOf<Map<String,String>>()
                val directory=File(cacheDir,"narad-shares").apply{mkdirs()}
                for(uri in sharedUris) {
                    if(uri.scheme=="http" || uri.scheme=="https")continue
                    val displayName=contentResolver.query(uri,arrayOf(OpenableColumns.DISPLAY_NAME),null,null,null)?.use { cursor -> if(cursor.moveToFirst())cursor.getString(0) else null } ?: "Shared file"
                    val safeName=displayName.substringAfterLast('/').substringAfterLast('\\').filter{it.isLetterOrDigit() || it in " ._()-"}.trim().take(180).ifBlank{"Shared file"}
                    val destination=File(directory,"${UUID.randomUUID()}-$safeName")
                    val input=contentResolver.openInputStream(uri) ?: error("Cannot read shared file")
                    var total=0L
                    try {input.use {source -> destination.outputStream().buffered().use {target -> val buffer=ByteArray(64*1024);while(true){val count=source.read(buffer);if(count<0)break;total+=count;check(total<=100L*1024*1024){"Shared files are limited to 100 MB"};target.write(buffer,0,count)}}}}catch(error:Throwable){destination.delete();throw error}
                    files.add(mapOf("path" to destination.absolutePath,"name" to safeName))
                }
                val payload=SharedContentPayload.create(text,dataUrl,files)
                main.post {result.success(payload)}
            }catch(error:Exception){main.post {result.error("share_intent",error.message ?: "Could not read shared content",null)}}
        }
    }
    @Suppress("DEPRECATION")
    private fun streams(from:Intent):List<Uri> {
        val single=if(Build.VERSION.SDK_INT>=33)from.getParcelableExtra(Intent.EXTRA_STREAM,Uri::class.java) else from.getParcelableExtra(Intent.EXTRA_STREAM)
        val multiple=if(Build.VERSION.SDK_INT>=33)from.getParcelableArrayListExtra(Intent.EXTRA_STREAM,Uri::class.java) else from.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
        return multiple ?: listOfNotNull(single)
    }
    override fun onRequestPermissionsResult(requestCode:Int,permissions:Array<out String>,grantResults:IntArray) {
        super.onRequestPermissionsResult(requestCode,permissions,grantResults)
        if(requestCode==1905)MediaRuntime.permissionResult(this)
        if(requestCode==1904){val pending=cameraResult;cameraResult=null;pending?.success(grantResults.isNotEmpty() && grantResults[0]==PackageManager.PERMISSION_GRANTED)}
    }
    @Deprecated("Activity result API retained for the FlutterActivity host")
    override fun onActivityResult(requestCode:Int,resultCode:Int,data:Intent?) {
        super.onActivityResult(requestCode,resultCode,data)
        if(requestCode==1906){
            val pending=sharedFolderResult;sharedFolderResult=null
            val uri=data?.data
            if(resultCode!=Activity.RESULT_OK || data==null || uri==null){pending?.success(null);return}
            try {
                val flags=data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                contentResolver.takePersistableUriPermission(uri,flags)
                val folder=androidx.documentfile.provider.DocumentFile.fromTreeUri(this,uri) ?: error("Cannot access selected folder")
                check(folder.isDirectory && folder.canRead()){"Selected folder is unavailable"}
                pending?.success(mapOf("path" to uri.toString(),"label" to (folder.name ?: "Shared folder"),"writable" to folder.canWrite()))
            }catch(error:Exception){pending?.error("shared_folder",error.message,null)}
            return
        }
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
        flutterEngine?.let { MethodChannel(it.dartExecutor.binaryMessenger,"dev.narad/android").setMethodCallHandler(null) }
        MediaRuntime.detach(this)
        sharedFolderResult?.error("cancelled","Folder selection cancelled",null);sharedFolderResult=null
        cameraResult?.error("cancelled","Camera permission cancelled",null);cameraResult=null
        adminResult?.error("cancelled","Device admin setup cancelled",null);adminResult=null
        exportResult?.error("cancelled","Save cancelled",null);exportResult=null;exportSource=null
        io.shutdown()
        super.onDestroy()
    }
}
