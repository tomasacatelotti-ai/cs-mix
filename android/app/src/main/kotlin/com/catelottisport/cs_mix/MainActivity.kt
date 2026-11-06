package com.catelottisport.cs_mix

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Handler
import android.os.Looper
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import java.io.File
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        var channel: MethodChannel? = null

        /** Link shared to CS Mix (see ShareActivity) until Dart asks for it. */
        var sharedText: String? = null
    }

    private var deviceCallback: AudioDeviceCallback? = null
    private var pickResult: MethodChannel.Result? = null
    private val pickRequest = 4711

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 2)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "cs_mix/native")
        channel = ch
        // Tell Dart when outputs come and go (Bluetooth reconnects, headphones plugged).
        val am = getSystemService(AUDIO_SERVICE) as AudioManager
        deviceCallback?.let { am.unregisterAudioDeviceCallback(it) }
        val cb = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(added: Array<out AudioDeviceInfo>?) {
                channel?.invokeMethod("devicesChanged", null)
            }
            override fun onAudioDevicesRemoved(removed: Array<out AudioDeviceInfo>?) {
                channel?.invokeMethod("devicesChanged", null)
            }
        }
        deviceCallback = cb
        am.registerAudioDeviceCallback(cb, Handler(Looper.getMainLooper()))
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "appDir" -> result.success(filesDir.absolutePath)
                "takeSharedLink" -> {
                    result.success(sharedText)
                    sharedText = null
                }
                "deviceName" -> result.success("${Build.MANUFACTURER} ${Build.MODEL}")
                "externalRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                "storageRoots" -> result.success(storageRoots())
                "hasStorage" -> result.success(hasStorage())
                "requestStorage" -> {
                    requestStorage()
                    result.success(null)
                }
                "pickFolder" -> pickFolder(call.argument<String>("initial"), result)
                "outputDevices" -> result.success(outputDevices())
                "serviceUpdate" -> {
                    val title = call.argument<String>("title") ?: "CS Mix"
                    val playing = call.argument<Boolean>("playing") ?: false
                    PlaybackService.update(this, title, playing)
                    result.success(null)
                }
                "serviceStop" -> {
                    PlaybackService.stop(this)
                    result.success(null)
                }
                "keepScreenOn" -> {
                    if (call.arguments == true) {
                        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    } else {
                        window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        deviceCallback?.let { (getSystemService(AUDIO_SERVICE) as AudioManager).unregisterAudioDeviceCallback(it) }
        deviceCallback = null
        channel = null
        super.onDestroy()
        if (isFinishing) {
            // The audio engine lives in this process: without the screen it would keep
            // playing with no controls, so closing the app really closes it.
            PlaybackService.stop(this)
            android.os.Process.killProcess(android.os.Process.myPid())
        }
    }

    private fun hasStorage(): Boolean =
        if (Build.VERSION.SDK_INT >= 30) {
            Environment.isExternalStorageManager()
        } else {
            checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
        }

    private fun requestStorage() {
        if (Build.VERSION.SDK_INT >= 30) {
            try {
                startActivity(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))
                )
            } catch (e: Exception) {
                startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
            }
        } else {
            requestPermissions(
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
                1
            )
        }
    }

    /** Android's own folder chooser (the pop-up window). Replies with a path, null if cancelled, "?" if unusable. */
    private fun pickFolder(initial: String?, result: MethodChannel.Result) {
        pickResult?.success(null)
        pickResult = result
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        if (Build.VERSION.SDK_INT >= 26 && initial != null) {
            pathToDocId(initial)?.let {
                i.putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    DocumentsContract.buildDocumentUri("com.android.externalstorage.documents", it)
                )
            }
        }
        try {
            startActivityForResult(i, pickRequest)
        } catch (e: Exception) {
            pickResult = null
            result.success("?")
        }
    }

    @Deprecated("Flutter still routes results through onActivityResult")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != pickRequest) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }
        val r = pickResult ?: return
        pickResult = null
        val uri = if (resultCode == RESULT_OK) data?.data else null
        if (uri == null) {
            r.success(null)
            return
        }
        r.success(treeToPath(uri) ?: "?")
    }

    /** "/storage/emulated/0/Music" → "primary:Music"; "/storage/1A2B-3C4D/x" → "1A2B-3C4D:x". */
    private fun pathToDocId(path: String): String? {
        val ext = Environment.getExternalStorageDirectory().absolutePath
        if (path == ext || path.startsWith("$ext/")) return "primary:" + path.removePrefix(ext).trimStart('/')
        val m = Regex("^/storage/([^/]+)/?(.*)$").find(path) ?: return null
        return m.groupValues[1] + ":" + m.groupValues[2]
    }

    /** Folder chosen in the system window → real path (CS Mix reads files with "all files" access). */
    private fun treeToPath(uri: Uri): String? {
        val id = try { DocumentsContract.getTreeDocumentId(uri) } catch (e: Exception) { return null }
        val c = id.indexOf(':')
        if (c < 0) return null
        val vol = id.substring(0, c)
        val rel = id.substring(c + 1).trim('/')
        val base = if (vol.equals("primary", ignoreCase = true)) Environment.getExternalStorageDirectory().absolutePath else "/storage/$vol"
        val p = if (rel.isEmpty()) base else "$base/$rel"
        return if (File(p).isDirectory) p else null
    }

    /** SD cards and USB drives, as "/storage/XXXX-XXXX". */
    private fun storageRoots(): List<String> {
        val out = mutableListOf<String>()
        for (d in getExternalFilesDirs(null)) {
            if (d == null) continue
            val p = d.absolutePath
            val i = p.indexOf("/Android/data")
            if (i > 0) out.add(p.substring(0, i))
        }
        return out
    }

    private fun outputDevices(): List<Map<String, Any>> {
        val am = getSystemService(AUDIO_SERVICE) as AudioManager
        val out = mutableListOf<Map<String, Any>>()
        for (d in am.getDevices(AudioManager.GET_DEVICES_OUTPUTS)) {
            if (!d.isSink) continue
            val kind = when (d.type) {
                AudioDeviceInfo.TYPE_BLUETOOTH_A2DP, 26 /* BLE_HEADSET */, 27 /* BLE_SPEAKER */ -> "bluetooth"
                AudioDeviceInfo.TYPE_WIRED_HEADPHONES, AudioDeviceInfo.TYPE_WIRED_HEADSET -> "headphones"
                AudioDeviceInfo.TYPE_USB_HEADSET, AudioDeviceInfo.TYPE_USB_DEVICE, AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb"
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER -> "speaker"
                else -> null
            } ?: continue
            out.add(mapOf("id" to d.id, "kind" to kind, "name" to (d.productName?.toString() ?: kind)))
        }
        return out
    }
}
