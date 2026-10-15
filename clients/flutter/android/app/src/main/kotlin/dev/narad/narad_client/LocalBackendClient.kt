package dev.narad.narad_client

import android.content.Context
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.io.File
import java.net.InetSocketAddress
import java.net.Socket

/** Private authenticated IPC shared by widget configuration and execution. */
object LocalBackendClient {
    fun call(context:Context, command:JSONObject, timeout:Int=15000):JSONObject {
        val token=File(NaradService.stateDirectory(context),"api-token").readText()
        Socket().use {socket ->
            socket.connect(InetSocketAddress("127.0.0.1",NaradService.API_PORT),1000)
            socket.soTimeout=timeout
            socket.getOutputStream().write((JSONObject().put("token",token).put("command",command).toString()+"\n").toByteArray(Charsets.UTF_8))
            val bytes=ByteArrayOutputStream()
            val input=socket.getInputStream().buffered()
            while(true) {
                val byte=input.read()
                check(byte>=0){"Backend disconnected"}
                if(byte==10)break
                check(bytes.size()<512*1024){"Backend response too large"}
                bytes.write(byte)
            }
            val response=JSONObject(bytes.toString("UTF-8"))
            check(response.optBoolean("ok")){response.optString("error","Request failed")}
            return response
        }
    }
    fun awaitReady(context:Context) {
        for(attempt in 0 until 100) {
            try {call(context,JSONObject().put("op","status"),1000);return}
            catch(_:Exception){Thread.sleep(100)}
        }
        error("Open Narad and check the connection service")
    }
}
