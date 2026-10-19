package dev.narad.narad_client

import io.flutter.plugin.common.StandardMethodCodec
import org.junit.Assert.*
import org.junit.Test

class SharedContentPayloadTest {
    @Test fun urlShareEncodesThroughFlutterChannel() {
        val payload=SharedContentPayload.create("https://example.com/path?q=hello#section",null,emptyList())
        val envelope=StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(payload)
        envelope.flip()
        val decoded=StandardMethodCodec.INSTANCE.decodeEnvelope(envelope) as Map<*,*>
        assertEquals("https://example.com/path?q=hello#section",decoded["text"])
        assertEquals(emptyList<Any>(),decoded["files"])
    }
    @Test fun urlWithFilePreviewEncodesNestedFiles() {
        val files=listOf(mapOf("path" to "/cache/preview.png","name" to "preview.png"))
        val payload=SharedContentPayload.create("https://example.com",null,files)
        val envelope=StandardMethodCodec.INSTANCE.encodeSuccessEnvelope(payload)
        envelope.flip()
        val decoded=StandardMethodCodec.INSTANCE.decodeEnvelope(envelope) as Map<*,*>
        assertEquals(files,decoded["files"])
    }
}
