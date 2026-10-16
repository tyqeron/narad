package dev.narad.narad_client

/** Shared widget policy; no cached grants or scripts. Receiver still authorizes each request. */
data class WidgetDeviceAction(val id:String,val label:String,val icon:Int=0)
object DeviceWidgetModel {
    val actions=listOf(
        WidgetDeviceAction("phone","Phone companion"),
        WidgetDeviceAction("file","Send file"),WidgetDeviceAction("clipboard","Send clipboard"),
        WidgetDeviceAction("audio","Send audio"),WidgetDeviceAction("camera","View camera"),
        WidgetDeviceAction("browse","Browse files"),WidgetDeviceAction("command","Run command"),
        WidgetDeviceAction("lock","Lock device"),WidgetDeviceAction("unlock","Request unlock"),
        WidgetDeviceAction("settings","Device settings"),WidgetDeviceAction("unpair","Unpair device")
    )
    fun actionsFor(platform:String)=actions.filter{
        (it.id!="phone" || platform in listOf("android","ios")) &&
        (it.id!="unlock" || platform!="windows") &&
        (platform!="ios" || it.id !in listOf("command","lock","unlock"))
    }
    fun enabled(action:String,online:Boolean)=online || action=="settings" || action=="unpair"
    fun known(action:String)=actions.any{it.id==action}
    fun title(names:List<String>)=when(names.size){0->"Narad · No devices connected";1->"Narad · 1 device connected";else->"Narad · ${names.size} devices connected"}
    fun details(names:List<String>)=if(names.isEmpty())"Ready for your paired devices" else "Connected to "+names.sortedWith(String.CASE_INSENSITIVE_ORDER).joinToString(", ")
}
