package org.buetow.turbonotes

import android.content.Intent

/**
 * Opens a note another app names, creating it when it does not exist yet:
 * Player's "Note in TurboNotes" button for the audiobook or podcast episode
 * playing. The path is relative to the notes folder; the Flutter side
 * (`lib/services/note_link.dart`) validates it like a typed path, so a link
 * can never reach outside the folder or overwrite a note.
 *
 * Example: `adb shell am start -a org.buetow.turbonotes.OPEN_NOTE
 * --es org.buetow.turbonotes.extra.PATH Book-And-Podcast-Notes/Dune.md
 * --es org.buetow.turbonotes.extra.TITLE Dune`
 */
internal object NoteLinks {
    const val ACTION_OPEN_NOTE = "org.buetow.turbonotes.OPEN_NOTE"
    const val EXTRA_PATH = "org.buetow.turbonotes.extra.PATH"
    const val EXTRA_TITLE = "org.buetow.turbonotes.extra.TITLE"

    /** The note [intent] asks for, or null when it is no note link. */
    fun describe(intent: Intent?): Map<String, String>? {
        if (intent?.action != ACTION_OPEN_NOTE) return null
        val path = intent.getStringExtra(EXTRA_PATH)?.takeIf { it.isNotBlank() } ?: return null
        val title = intent.getStringExtra(EXTRA_TITLE)
        return if (title.isNullOrBlank()) mapOf("path" to path) else mapOf("path" to path, "title" to title)
    }
}
