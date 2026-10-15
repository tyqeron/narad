package dev.narad.narad_client

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** AES-GCM wrapping with a non-exportable per-install Android Keystore key. */
class IdentityVault(private val directory: File) {
    private val alias = "narad.identity.v1"
    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        if (store.containsAlias(alias)) return store.getKey(alias, null) as SecretKey
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).setRandomizedEncryptionRequired(true).build())
        }.generateKey()
    }
    fun loadOrCreate(): JSONObject {
        directory.mkdirs()
        val file = AtomicFile(File(directory, "identity.enc"))
        if (file.baseFile.exists() || File(directory,"identity.enc.bak").exists()) {
            val data = file.readFully()
            require(data.size >= 28) { "Stored identity is truncated" }
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, data.copyOfRange(0,12)))
            // Authentication failure must surface; never silently replace an existing identity.
            val plaintext = cipher.doFinal(data.copyOfRange(12,data.size))
            return try { JSONObject(String(plaintext, Charsets.UTF_8)) } finally { plaintext.fill(0) }
        }
        val generated = JSONObject(NativeBackend.generateIdentity())
        check(generated.optBoolean("ok")) { generated.optString("error", "Identity generation failed") }
        val identity = generated.getJSONObject("identity")
        val plaintext = identity.toString().toByteArray(Charsets.UTF_8)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE,key())
        val output = file.startWrite()
        try {
            output.write(cipher.iv)
            output.write(cipher.doFinal(plaintext))
            file.finishWrite(output)
        } catch (error: Exception) { file.failWrite(output); throw error }
        finally { plaintext.fill(0) }
        return identity
    }
}
