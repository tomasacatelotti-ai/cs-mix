package com.catelottisport.cs_mix

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import android.os.PowerManager

/** Keeps the process in the foreground while music plays, with play/pause and next controls. */
class PlaybackService : Service() {
    companion object {
        private const val CHANNEL = "cs_mix_playback"
        private const val NOTIFICATION_ID = 1

        var instance: PlaybackService? = null

        fun update(ctx: Context, title: String, playing: Boolean) {
            val running = instance
            if (running != null) {
                // Already in the foreground: just refresh the notification.
                running.refresh(title, playing)
                return
            }
            val i = Intent(ctx, PlaybackService::class.java)
                .putExtra("title", title)
                .putExtra("playing", playing)
            try {
                if (Build.VERSION.SDK_INT >= 26) ctx.startForegroundService(i) else ctx.startService(i)
            } catch (e: Exception) {
                // Starting from the background can be refused; playback itself keeps going.
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, PlaybackService::class.java))
        }
    }

    private var wake: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == "toggle" || action == "next" || action == "stop") {
            MainActivity.channel?.invokeMethod("media", action)
            return START_NOT_STICKY
        }
        val title = intent?.getStringExtra("title") ?: "CS Mix"
        val playing = intent?.getBooleanExtra("playing", false) ?: false
        val n = build(title, playing)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(NOTIFICATION_ID, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK)
        } else {
            startForeground(NOTIFICATION_ID, n)
        }
        instance = this
        wakeFor(playing)
        return START_NOT_STICKY
    }

    fun refresh(title: String, playing: Boolean) {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIFICATION_ID, build(title, playing))
        wakeFor(playing)
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // Swiped away from recents: stop the music together with the app.
        stopSelf()
        android.os.Process.killProcess(android.os.Process.myPid())
    }

    private fun wakeFor(playing: Boolean) {
        if (playing) {
            if (wake == null) {
                val pm = getSystemService(POWER_SERVICE) as PowerManager
                wake = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "csmix:playback").apply {
                    setReferenceCounted(false)
                }
            }
            wake?.acquire(6 * 60 * 60 * 1000L)
        } else if (wake?.isHeld == true) {
            wake?.release()
        }
    }

    override fun onDestroy() {
        if (wake?.isHeld == true) wake?.release()
        wake = null
        instance = null
        super.onDestroy()
    }

    private fun pending(action: String, code: Int): PendingIntent =
        PendingIntent.getService(
            this, code, Intent(this, PlaybackService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

    private fun build(title: String, playing: Boolean): Notification {
        val nm = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        val b = if (Build.VERSION.SDK_INT >= 26) {
            if (nm.getNotificationChannel(CHANNEL) == null) {
                val ch = NotificationChannel(CHANNEL, "Reproducción", NotificationManager.IMPORTANCE_LOW)
                ch.setShowBadge(false)
                nm.createNotificationChannel(ch)
            }
            Notification.Builder(this, CHANNEL)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        val open = PendingIntent.getActivity(
            this, 0, Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val toggle = Notification.Action.Builder(
            Icon.createWithResource(this, if (playing) android.R.drawable.ic_media_pause else android.R.drawable.ic_media_play),
            if (playing) "Pausa" else "Reproducir",
            pending("toggle", 1)
        ).build()
        val next = Notification.Action.Builder(
            Icon.createWithResource(this, android.R.drawable.ic_media_next), "Próximo", pending("next", 2)
        ).build()
        return b.setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(if (playing) "Sonando en CS Mix" else "En pausa")
            .setContentIntent(open)
            .setOngoing(playing)
            .setShowWhen(false)
            .addAction(toggle)
            .addAction(next)
            .setStyle(Notification.MediaStyle().setShowActionsInCompactView(0, 1))
            .build()
    }
}
