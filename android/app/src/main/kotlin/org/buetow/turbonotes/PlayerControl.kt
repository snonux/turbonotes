package org.buetow.turbonotes

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.service.notification.NotificationListenerService
import io.flutter.plugin.common.MethodChannel

/**
 * Exists only so the user can grant TurboNotes notification access, which is
 * what Android asks of an app before it may see other apps' media sessions.
 * No notification is ever read.
 */
class PlayerSessionListener : NotificationListenerService()

/**
 * Controls the Player app (audiobooks) from the note editor through its
 * media session: pause, continue, and rewind. Status changes are pushed to
 * Dart as `changed`, with null while Player has no title open.
 */
internal class PlayerControl(private val context: Context, private val channel: MethodChannel) {
    private val sessions = context.getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager
    private val listener = ComponentName(context, PlayerSessionListener::class.java)
    private val main = Handler(Looper.getMainLooper())
    private var watching = false
    private var player: MediaController? = null
    private var lastStatus: Map<String, Any?>? = null

    private val sessionsChanged = MediaSessionManager.OnActiveSessionsChangedListener { controllers ->
        attach(controllers.orEmpty())
    }

    private val playerChanged = object : MediaController.Callback() {
        override fun onPlaybackStateChanged(state: PlaybackState?) = publish()
        override fun onMetadataChanged(metadata: MediaMetadata?) = publish()
        override fun onSessionDestroyed() = attach(emptyList())
    }

    fun handle(method: String, seconds: Int?, result: MethodChannel.Result) {
        when (method) {
            "status" -> {
                watch()
                result.success(mapOf("access" to hasAccess(), "player" to status()))
            }
            "requestAccess" -> {
                openAccessSettings()
                result.success(null)
            }
            "pause" -> result.success(withPlayer { it.transportControls.pause() })
            "play" -> result.success(withPlayer { it.transportControls.play() })
            "rewind" -> result.success(withPlayer { rewind(it, (seconds ?: 10) * 1000L) })
            else -> result.notImplemented()
        }
    }

    /** Follows Player's session once access is granted; safe to call again. */
    private fun watch() {
        if (watching || !hasAccess()) {
            if (watching) attach(activeSessions())
            return
        }
        try {
            sessions.addOnActiveSessionsChangedListener(sessionsChanged, listener, main)
            watching = true
        } catch (_: SecurityException) {
            return
        }
        attach(activeSessions())
    }

    fun dispose() {
        if (watching) sessions.removeOnActiveSessionsChangedListener(sessionsChanged)
        watching = false
        player?.unregisterCallback(playerChanged)
        player = null
    }

    private fun activeSessions(): List<MediaController> = try {
        sessions.getActiveSessions(listener)
    } catch (_: SecurityException) {
        emptyList()
    }

    private fun attach(controllers: List<MediaController>) {
        val next = controllers.firstOrNull { isPlayer(it.packageName) }
        if (next?.sessionToken != player?.sessionToken) {
            player?.unregisterCallback(playerChanged)
            player = next
            next?.registerCallback(playerChanged, main)
        }
        publish()
    }

    private fun publish() {
        val status = status()
        if (status == lastStatus) return
        lastStatus = status
        channel.invokeMethod("changed", status)
    }

    /** Player's title and whether it plays, or null while no title is open. */
    private fun status(): Map<String, Any?>? {
        val controller = player ?: return null
        val state = controller.playbackState?.state ?: return null
        if (state == PlaybackState.STATE_NONE ||
            state == PlaybackState.STATE_STOPPED ||
            state == PlaybackState.STATE_ERROR
        ) {
            return null
        }
        val metadata = controller.metadata ?: return null
        val title = metadata.getString(MediaMetadata.METADATA_KEY_TITLE)
            ?: metadata.description?.title?.toString()
        if (title.isNullOrBlank()) return null
        return mapOf(
            "title" to title,
            "playing" to (state == PlaybackState.STATE_PLAYING ||
                state == PlaybackState.STATE_BUFFERING ||
                state == PlaybackState.STATE_CONNECTING),
        )
    }

    /** Runs [action] on Player's session; false when no title is open. */
    private fun withPlayer(action: (MediaController) -> Unit): Boolean {
        val controller = player ?: return false
        if (status() == null) return false
        action(controller)
        return true
    }

    private fun rewind(controller: MediaController, millis: Long) {
        val state = controller.playbackState ?: return
        if (state.actions and PlaybackState.ACTION_SEEK_TO == 0L) {
            controller.transportControls.rewind()
            return
        }
        controller.transportControls.seekTo((position(state) - millis).coerceAtLeast(0))
    }

    /** Where playback is now: the reported position moves on while playing. */
    private fun position(state: PlaybackState): Long {
        if (state.state != PlaybackState.STATE_PLAYING) return state.position
        val elapsed = SystemClock.elapsedRealtime() - state.lastPositionUpdateTime
        return state.position + (elapsed * state.playbackSpeed).toLong()
    }

    private fun hasAccess(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            val manager = context.getSystemService(android.app.NotificationManager::class.java)
            return manager.isNotificationListenerAccessGranted(listener)
        }
        val enabled = Settings.Secure.getString(context.contentResolver, "enabled_notification_listeners")
        return enabled?.split(':')?.any { ComponentName.unflattenFromString(it) == listener } == true
    }

    private fun openAccessSettings() {
        val detail = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Intent(Settings.ACTION_NOTIFICATION_LISTENER_DETAIL_SETTINGS)
                .putExtra(Settings.EXTRA_NOTIFICATION_LISTENER_COMPONENT_NAME, listener.flattenToString())
        } else {
            null
        }
        val intents = listOfNotNull(detail, Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
        for (intent in intents) {
            try {
                context.startActivity(intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                return
            } catch (_: Exception) {
                // Some builds lack the detail page; fall back to the list.
            }
        }
    }

    companion object {
        /** Player's application id; debug and flavour builds add a suffix. */
        private const val playerPackage = "zone.foo.player_android"

        fun isPlayer(packageName: String): Boolean =
            packageName == playerPackage || packageName.startsWith("$playerPackage.")
    }
}
