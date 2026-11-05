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
import android.provider.Settings
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        var channel: MethodChannel? = null
    }

    private var deviceCallback: AudioDeviceCallback? = null

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
                "deviceName" -> result.success("${Build.MANUFACTURER} ${Build.MODEL}")
                "externalRoot" -> result.success(Environment.getExternalStorageDirectory().absolutePath)
                "storageRoots" -> result.success(storageRoots())
                "hasStorage" -> result.success(hasStorage())
                "requestStorage" -> {
                    requestStorage()
                    result.success(null)
                }
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
