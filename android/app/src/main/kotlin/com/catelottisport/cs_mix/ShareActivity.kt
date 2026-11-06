package com.catelottisport.cs_mix

import android.app.Activity
import android.content.Intent
import android.os.Bundle

/**
 * Receives a link shared from another app ("Compartir" → "Descargar en CS Mix").
 *
 * It never shows anything: it hands the text to CS Mix and brings CS Mix to the front the same
 * way the launcher icon does. Opening MainActivity directly here would start a second copy inside
 * the other app's task, with a second engine fighting the one that is playing.
 */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val text = if (intent?.action == Intent.ACTION_SEND) intent.getStringExtra(Intent.EXTRA_TEXT) else null
        if (!text.isNullOrBlank()) {
            // Kept for a cold start (Dart asks for it when it's ready) and sent now if CS Mix is running.
            MainActivity.sharedText = text
            MainActivity.channel?.invokeMethod("sharedLink", text)
        }
        packageManager.getLaunchIntentForPackage(packageName)?.let {
            it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED)
            startActivity(it)
        }
        finish()
    }
}
