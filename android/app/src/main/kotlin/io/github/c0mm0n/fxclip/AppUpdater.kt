package io.github.c0mm0n.fxclip

import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import android.util.AtomicFile
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.core.content.FileProvider
import androidx.lifecycle.AndroidViewModel
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.isActive
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.coroutines.coroutineContext

/** Lives across rotation. Only explicit checks or an opted-in opening contact GitHub. */
class AppUpdater(application: Application) : AndroidViewModel(application) {
    private val app = application
    private val preferences = app.getSharedPreferences("updates", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val directory = File(app.filesDir, "updates")
    private val apk = File(directory, "update.apk")
    private val part = File(directory, "update.apk.part")
    private val metadata = AtomicFile(File(directory, "verified.json"))
    private var verifiedRelease: UpdateRelease? = null
    private var job: Job? = null
    private var cancelRequested = false
    @Volatile private var connection: HttpURLConnection? = null

    var automatic by mutableStateOf(preferences.getBoolean("automaticChecks", false)); private set
    var busy by mutableStateOf(false); private set
    var downloading by mutableStateOf(false); private set
    var ready by mutableStateOf(false); private set
    var progress by mutableIntStateOf(0); private set
    var release by mutableStateOf<UpdateRelease?>(null); private set
    var status by mutableStateOf(app.getString(R.string.update_idle)); private set

    init {
        part.delete()
        if (metadata.baseFile.exists() && apk.exists()) {
            busy = true; status = app.getString(R.string.update_restoring)
            job = scope.launch {
                try {
                    val saved = withContext(Dispatchers.IO) {
                        val value = metadata.openRead().bufferedReader().use { it.readText() }
                        UpdateRelease.parse(JSONObject(value), BuildConfig.VERSION_NAME)?.also { verifyApk(apk, it) }
                    }
                    if (saved == null) { clearDownload(); status = app.getString(R.string.update_idle) } else {
                        release = saved; verifiedRelease = saved; ready = true
                        status = app.getString(R.string.update_ready, saved.version)
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) {
                    clearDownload(); status = app.getString(R.string.update_restore_failed)
                } finally { busy = false; if (scope.isActive) onOpen() }
            }
        } else clearDownload()
    }

    fun onOpen() {
        if (automatic && !busy && System.currentTimeMillis() - preferences.getLong("lastCheck", 0) >= 86400000L) check()
    }

    fun setAutomaticChecks(enabled: Boolean) {
        automatic = enabled
        preferences.edit().putBoolean("automaticChecks", enabled).apply()
        if (enabled) onOpen()
    }

    fun check() {
        if (busy) return
        busy = true; status = app.getString(R.string.update_checking)
        job = scope.launch {
            try {
                val candidate = withContext(Dispatchers.IO) {
                    preferences.edit().putLong("lastCheck", System.currentTimeMillis()).commit()
                    val request = connect(BuildConfig.UPDATE_API)
                    val body = try {
                        request.inputStream.use { stream ->
                            val bytes = stream.readBytesLimited(1024 * 1024)
                            String(bytes, Charsets.UTF_8)
                        }
                    } finally { request.disconnect(); connection = null }
                    UpdateRelease.parse(JSONObject(body), BuildConfig.VERSION_NAME)
                }
                release = candidate
                ready = candidate != null && candidate == verifiedRelease && apk.exists()
                if (candidate == null) { clearDownload(); status = app.getString(R.string.update_current) }
                else status = app.getString(if (ready) R.string.update_ready else R.string.update_available, candidate.version)
            } catch (_: CancellationException) { /* Activity cleanup never starts another request. */ }
            catch (_: Exception) { status = app.getString(R.string.update_check_failed) }
            finally { busy = false }
        }
    }

    fun download() {
        val candidate = release ?: return
        if (busy) return
        cancelRequested = false
        busy = true; downloading = true; progress = 0
        status = app.getString(R.string.update_downloading)
        job = scope.launch {
            try {
                withContext(Dispatchers.IO) {
                    directory.mkdirs()
                    val request = connect(candidate.url)
                    try {
                        request.inputStream.use { input ->
                            part.outputStream().use { output ->
                                val buffer = ByteArray(65536); var written = 0L; var lastProgress = -1
                                while (true) {
                                    coroutineContext.ensureActive()
                                    val count = input.read(buffer)
                                    if (count < 0) break
                                    written += count
                                    if (written > candidate.size) throw IOException("Unexpected download size")
                                    output.write(buffer, 0, count)
                                    val percent = (written * 100 / candidate.size).toInt()
                                    if (percent != lastProgress) { lastProgress = percent; withContext(Dispatchers.Main) { progress = percent } }
                                }
                                output.fd.sync()
                            }
                        }
                    } finally { request.disconnect(); connection = null }
                    verifyApk(part, candidate)
                    coroutineContext.ensureActive()
                    if (!part.renameTo(apk)) throw IOException("Could not save update")
                    val output = metadata.startWrite()
                    try { output.write(candidate.json().toString().toByteArray()); metadata.finishWrite(output) }
                    catch (error: Exception) { metadata.failWrite(output); throw error }
                }
                verifiedRelease = candidate; ready = true
                status = app.getString(R.string.update_ready, candidate.version)
            } catch (_: CancellationException) { status = app.getString(R.string.update_cancelled) }
            catch (error: Exception) {
                status = app.getString(when {
                    cancelRequested -> R.string.update_cancelled
                    error is InvalidApk -> error.messageId
                    else -> R.string.update_download_failed
                })
            }
            finally { part.delete(); if (cancelRequested) clearDownload(); downloading = false; busy = false }
        }
    }

    fun cancelDownload() { if (downloading) { cancelRequested = true; job?.cancel(); connection?.disconnect() } }

    /** Recheck private bytes and the installed package immediately before granting an APK URI. */
    suspend fun installationIntent(): Intent? {
        val candidate = verifiedRelease ?: return null
        if (busy || !ready) return null
        busy = true; status = app.getString(R.string.update_preparing)
        return try {
            withContext(Dispatchers.IO) { verifyApk(apk, candidate) }
            val uri = FileProvider.getUriForFile(app, app.packageName + ".updates", apk)
            status = app.getString(R.string.update_installer_open)
            Intent(Intent.ACTION_VIEW).setDataAndType(uri, "application/vnd.android.package-archive")
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION).putExtra(Intent.EXTRA_RETURN_RESULT, true)
        } catch (error: CancellationException) { throw error }
        catch (error: InvalidApk) { clearDownload(); status = app.getString(error.messageId); null }
        catch (_: Exception) { status = app.getString(R.string.update_install_failed); null }
        finally { busy = false }
    }

    fun permissionNeeded() { status = app.getString(R.string.update_permission_return) }
    fun permissionGranted() { verifiedRelease?.let { status = app.getString(R.string.update_ready, it.version) } }
    fun installerClosed() { status = app.getString(R.string.update_installer_closed) }
    fun cannotOpenInstaller() { status = app.getString(R.string.update_install_failed) }

    @Suppress("DEPRECATION")
    internal fun verifyApk(file: File, candidate: UpdateRelease) {
        if (file.length() != candidate.size) throw InvalidApk(R.string.update_invalid_apk)
        val hash = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { stream ->
            val buffer = ByteArray(65536)
            while (true) { val count = stream.read(buffer); if (count < 0) break; hash.update(buffer, 0, count) }
        }
        if (hash.digest().joinToString("") { "%02x".format(it) } != candidate.sha256) throw InvalidApk(R.string.update_invalid_apk)
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES else PackageManager.GET_SIGNATURES
        val next = app.packageManager.getPackageArchiveInfo(file.absolutePath, flags) ?: throw InvalidApk(R.string.update_invalid_apk)
        val installed = app.packageManager.getPackageInfo(app.packageName, flags)
        if (next.packageName != app.packageName || next.versionName != candidate.version) throw InvalidApk(R.string.update_wrong_package)
        fun code(info: PackageInfo): Long = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()
        if (code(next) <= code(installed)) throw InvalidApk(R.string.update_old_code)
        if ((next.applicationInfo?.minSdkVersion ?: Int.MAX_VALUE) > Build.VERSION.SDK_INT) throw InvalidApk(R.string.update_unsupported)
        fun signers(info: PackageInfo): Set<String> =
            (if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners else info.signatures)
                .orEmpty().map { signature -> signature.toByteArray().joinToString("") { "%02x".format(it) } }.toSet()
        val currentSigners = signers(installed)
        if (currentSigners.isEmpty() || currentSigners != signers(next)) throw InvalidApk(R.string.update_wrong_signature)
    }

    private fun connect(address: String): HttpURLConnection {
        var url = URL(address)
        repeat(6) {
            val local = BuildConfig.DEBUG && url.protocol == "http" && url.host == "127.0.0.1"
            if (url.protocol != "https" && !local) throw IOException("HTTPS required")
            val request = url.openConnection() as HttpURLConnection
            connection = request
            request.connectTimeout = 15000; request.readTimeout = 15000
            request.instanceFollowRedirects = false
            request.setRequestProperty("User-Agent", "fxclip/" + BuildConfig.VERSION_NAME)
            request.setRequestProperty("Accept-Encoding", "identity")
            var keepOpen = false
            try {
                val code = request.responseCode
                if (code in 300..399) {
                    val next = request.getHeaderField("Location") ?: throw IOException("Missing redirect")
                    url = URL(url, next)
                } else if (code == 200) { keepOpen = true; return request }
                else throw IOException("GitHub download unavailable")
            } finally { if (!keepOpen) { request.disconnect(); connection = null } }
        }
        throw IOException("Too many redirects")
    }

    private fun java.io.InputStream.readBytesLimited(limit: Int): ByteArray {
        val output = java.io.ByteArrayOutputStream()
        val buffer = ByteArray(8192)
        while (true) {
            val count = read(buffer); if (count < 0) break
            if (output.size() + count > limit) throw IOException("Update information too large")
            output.write(buffer, 0, count)
        }
        return output.toByteArray()
    }

    private fun clearDownload() { apk.delete(); metadata.delete(); verifiedRelease = null; ready = false }
    override fun onCleared() { scope.cancel(); connection?.disconnect(); super.onCleared() }
    internal class InvalidApk(val messageId: Int) : IOException()
}
