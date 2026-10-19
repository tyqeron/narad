package dev.narad.narad_client

/** StandardMethodCodec supports maps/lists, not org.json containers. */
object SharedContentPayload {
    fun create(text: String?, url: String?, files: List<Map<String,String>>): Map<String,Any> =
        mapOf("text" to (text ?: ""), "url" to (url ?: ""), "files" to files)
}
