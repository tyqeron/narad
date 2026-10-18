package dev.narad.narad_client

import android.content.Context
import android.net.Uri
import android.util.Base64
import androidx.documentfile.provider.DocumentFile
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/** Persisted SAF trees only. No all-files permission and no remote absolute paths. */
object SharedDocuments {
    private fun call(context:Context,op:String,id:String):JSONObject { check(NaradService.state=="running"); return LocalBackendClient.call(context,JSONObject().put("op",op).put("id",id)).also{check(it.optBoolean("ok")){"Shared folder permission revoked"}} }
    private fun validName(name:String):Boolean=name.isNotEmpty() && name!="." && name!=".." && !name.contains('/') && !name.contains('\\') && !name.contains('\u0000')
    private fun child(root:DocumentFile,path:String):DocumentFile {
        require(path.length<=1024 && !path.startsWith('/')){"Invalid shared path"}
        var node=root
        for(name in path.split('/').filter{it.isNotEmpty()}) {
            require(validName(name)){"Invalid shared path"}
            val matches=node.listFiles().filter{it.name==name}
            check(matches.size==1){"File missing or ambiguous"}; node=matches.single()
        }
        return node
    }
    fun poll(context:Context) {
        val response=LocalBackendClient.call(context,JSONObject().put("op","storage_jobs"))
        if(!response.optBoolean("ok"))return
        val jobs=response.getJSONArray("jobs")
        for(i in 0 until jobs.length()) {
            val job=jobs.getJSONObject(i);val id=job.getString("id")
            val result=try {
                call(context,"storage_validate",id)
                val rootUri=Uri.parse(job.getString("root"));require(rootUri.scheme=="content")
                val root=DocumentFile.fromTreeUri(context,rootUri) ?: error("Folder unavailable")
                check(root.isDirectory && root.canRead()){"Folder permission expired"}
                val args=job.getJSONObject("args"); val path=args.getString("path")
                val node=child(root,path)
                when(job.getString("kind")) {
                    "list" -> {
                        check(node.isDirectory);val entries=JSONArray();var bytes=0
                        for(file in node.listFiles().take(257)) {
                            val name=file.name ?: continue
                            if(!validName(name))continue
                            val entry=JSONObject().put("name",name).put("directory",file.isDirectory).put("size",file.length())
                            bytes+=entry.toString().toByteArray(Charsets.UTF_8).size
                            if(bytes>58000)break
                            entries.put(entry)
                        }
                        JSONObject().put("ok",true).put("entries",entries)
                    }
                    "read" -> {
                        check(node.isFile);val offset=args.getLong("offset");val size=node.length();require(offset>=0 && offset<=size)
                        val data=context.contentResolver.openInputStream(node.uri)?.use{input ->
                            var left=offset
                            while(left>0){val n=input.skip(left);if(n>0)left-=n else {check(input.read()!=-1);left--}}
                            val buffer=ByteArray(48*1024);var used=0
                            while(used<buffer.size){val n=input.read(buffer,used,buffer.size-used);if(n<0)break;used+=n}
                            buffer.copyOf(used)
                        } ?: error("Cannot read file")
                        JSONObject().put("ok",true).put("data",Base64.encodeToString(data,Base64.NO_WRAP)).put("size",size).put("offset",offset).put("next",offset+data.size)
                    }
                    "publish" -> {
                        check(node.isDirectory && node.canWrite());val name=args.getString("name");require(validName(name))
                        check(node.listFiles().none{it.name==name}){"File exists"}
                        val source=File(args.getString("source")).canonicalFile
                        val staging=File(NaradService.stateDirectory(context),"share-completed").canonicalFile
                        check(source.toPath().startsWith(staging.toPath()) && source.isFile){"Invalid upload source"}
                        val temporary=node.createFile("application/octet-stream",".narad-upload-${args.getString("upload_id")}.part") ?: error("Cannot create upload")
                        try {
                            context.contentResolver.openOutputStream(temporary.uri,"wt")?.use {output ->
                                source.inputStream().use {input ->
                                    val buffer=ByteArray(64*1024);var total=0L;var checkAt=0L
                                    while(true){val n=input.read(buffer);if(n<0)break
                                        if(total>=checkAt){call(context,"storage_validate",id);checkAt=total+1024*1024}
                                        output.write(buffer,0,n);total+=n
                                    }
                                    output.flush()
                                }
                            } ?: error("Cannot write upload")
                            call(context,"storage_validate",id)
                            check(node.listFiles().none{it.name==name}){"File exists"}
                            check(temporary.renameTo(name)){"Provider cannot publish this upload"}
                        } catch(e:Exception){temporary.delete();throw e}
                        JSONObject().put("ok",true)
                    }
                    "mkdir" -> {
                        check(node.isDirectory && node.canWrite()){"Folder is read-only"}
                        val name=args.getString("name");require(validName(name))
                        check(node.listFiles().none{it.name==name}){"An item with this name already exists"}
                        check(node.createDirectory(name)!=null){"Folder could not be created by this provider"}
                        JSONObject().put("ok",true)
                    }
                    "delete" -> {
                        check(node.isDirectory && node.canWrite()){"Folder is read-only"}
                        val name=args.getString("name");require(validName(name))
                        val matches=node.listFiles().filter{it.name==name}
                        check(matches.size==1 && matches.single().isFile){"File is missing or cannot be removed"}
                        check(matches.single().delete()){"File could not be removed by this provider"}
                        JSONObject().put("ok",true)
                    }
                    else -> error("Unknown shared folder operation")
                }
            } catch(_:Exception){JSONObject().put("ok",false).put("error","Shared folder unavailable, read-only, or file already exists. Check folder access on the source device.")}
            try{LocalBackendClient.call(context,JSONObject().put("op","storage_result").put("id",id).put("result",result))}catch(_:Exception){}
        }
    }
}
