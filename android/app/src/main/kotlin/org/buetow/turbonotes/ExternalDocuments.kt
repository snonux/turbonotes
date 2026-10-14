package org.buetow.turbonotes

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import java.io.FileNotFoundException

/**
 * One text file another app handed over with "Edit" or "Open with" (a
 * content:// URI). TurboNotes reads it and writes the edits back through
 * the same URI, so the app that owns the file sees every save.
 */
/** Larger files are refused: they are not notes, and the editor would crawl. */
private const val maxTextBytes = 8 * 1024 * 1024

internal class ExternalDocuments(private val resolver: ContentResolver) {

    /** The document in [intent], or null when it carries none. */
    fun describe(intent: Intent?): Map<String, Any>? {
        if (intent == null) return null
        if (intent.action != Intent.ACTION_EDIT && intent.action != Intent.ACTION_VIEW) return null
        val uri = intent.data ?: return null
        if (uri.scheme != ContentResolver.SCHEME_CONTENT) return null
        val writable = intent.action == Intent.ACTION_EDIT ||
            intent.flags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION != 0
        return mapOf(
            "uri" to uri.toString(),
            "name" to displayName(uri),
            "writable" to writable,
        )
    }

    fun read(raw: String): String {
        val uri = Uri.parse(raw)
        val stream = resolver.openInputStream(uri)
            ?: throw FileNotFoundException("$uri cannot be read.")
        return stream.use { input ->
            val out = java.io.ByteArrayOutputStream()
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                out.write(buffer, 0, n)
                if (out.size() > maxTextBytes) throw java.io.IOException("The file is larger than 8 MB.")
            }
            out.toString(Charsets.UTF_8.name())
        }
    }

    fun write(raw: String, text: String) {
        val uri = Uri.parse(raw)
        // "wt" truncates; a few providers only know "w", which may not.
        val stream = try {
            resolver.openOutputStream(uri, "wt")
        } catch (e: IllegalArgumentException) {
            resolver.openOutputStream(uri, "w")
        } catch (e: FileNotFoundException) {
            resolver.openOutputStream(uri, "w")
        } ?: throw FileNotFoundException("$uri cannot be written.")
        stream.use { it.write(text.toByteArray(Charsets.UTF_8)) }
    }

    private fun displayName(uri: Uri): String {
        try {
            resolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    val name = cursor.getString(0)
                    if (!name.isNullOrEmpty()) return name
                }
            }
        } catch (e: Exception) {
            // Fall through to the URI: the name is only a label.
        }
        return uri.lastPathSegment?.substringAfterLast('/') ?: "Untitled.txt"
    }
}
