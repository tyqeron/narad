package dev.narad.narad_client

/** Arguments may contain identity keys. Never log calls or their serialized arguments. */
object NativeBackend {
    init { System.loadLibrary("narad_android") }
    @JvmStatic external fun generateIdentity(): String
    @JvmStatic external fun start(config: String): String
    @JvmStatic external fun stop(): String
    @JvmStatic external fun status(): String
}
