package org.buetow.turbonotes

import android.content.ContentResolver
import android.net.Uri
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import java.io.FileNotFoundException
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction
import java.util.concurrent.ConcurrentHashMap
import java.util.UUID

class NoteExistsException(message: String) : IOException(message)

/**
 * [bytes] as UTF-8, or an error for anything else, like Dart's
 * readAsString. A lenient decoder would swap bad bytes for U+FFFD, and the
 * next save would write that over the note.
 */
internal fun decodeUtf8(bytes: ByteArray, path: String): String = try {
    Charsets.UTF_8.newDecoder()
        .onMalformedInput(CodingErrorAction.REPORT)
        .onUnmappableCharacter(CodingErrorAction.REPORT)
        .decode(ByteBuffer.wrap(bytes))
        .toString()
} catch (e: CharacterCodingException) {
    throw IOException("$path is not UTF-8 text.")
}

/**
 * Markdown notes inside a document tree the user picked, addressed by
 * relative POSIX paths ("projects/todo.md") just like the Dart
 * DirectoryNoteStore. Paths arrive already normalized by the Dart side, but
 * every segment is checked again: a provider must never be asked for "..".
 */
internal class SafNotes(private val resolver: ContentResolver) {
    private data class Doc(
        val id: String,
        val name: String,
        val isDir: Boolean,
        val modified: Long = 0,
        val size: Long = 0,
    )

    /**
     * Document ids of the files the last [list] of each tree found, by path.
     * Finding a file otherwise lists every folder on its way, which on a
     * folder with many notes is what makes opening one slow. Only reads use
     * it, and a read that fails on a cached id walks the tree after all.
     */
    private val known = ConcurrentHashMap<String, Map<String, String>>()

    private fun forget(raw: String, path: String) {
        known.computeIfPresent(raw) { _, ids -> ids - path }
    }

    private fun tree(raw: String, write: Boolean): Uri {
        val tree = Uri.parse(raw)
        require(tree.scheme == ContentResolver.SCHEME_CONTENT && DocumentsContract.isTreeUri(tree)) {
            "A document tree URI is required."
        }
        val granted = resolver.persistedUriPermissions.any {
            it.uri == tree && it.isReadPermission && (!write || it.isWritePermission)
        }
        if (!granted) throw SecurityException("Access to the selected folder has expired. Select it again.")
        return tree
    }

    private fun segments(path: String): List<String> {
        val parts = path.split('/')
        require(parts.isNotEmpty() && parts.all { it.isNotEmpty() && it != "." && it != ".." && !it.startsWith(".") }) {
            "Invalid note path."
        }
        return parts
    }

    private fun children(tree: Uri, parentId: String): List<Doc> {
        val uri = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parentId)
        val columns = arrayOf(
            Document.COLUMN_DOCUMENT_ID,
            Document.COLUMN_DISPLAY_NAME,
            Document.COLUMN_MIME_TYPE,
            Document.COLUMN_LAST_MODIFIED,
            Document.COLUMN_SIZE,
        )
        val cursor = resolver.query(uri, columns, null, null, null)
            ?: throw IOException("Cannot list the selected folder.")
        cursor.use {
            val extras = it.extras
            if (extras.getBoolean(DocumentsContract.EXTRA_LOADING, false)) {
                throw IOException("The document provider is still loading this folder. Try again.")
            }
            extras.getString(DocumentsContract.EXTRA_ERROR)?.let { e -> throw IOException(e) }
            val result = mutableListOf<Doc>()
            while (it.moveToNext()) {
                val id = it.getString(0) ?: continue
                val name = it.getString(1) ?: continue
                // getLong reads a missing modification time or size as 0.
                result.add(Doc(id, name, it.getString(2) == Document.MIME_TYPE_DIR, it.getLong(3), it.getLong(4)))
            }
            return result
        }
    }

    private fun rootId(tree: Uri): String = DocumentsContract.getTreeDocumentId(tree)

    private fun find(tree: Uri, path: String): Doc? {
        var current = Doc(rootId(tree), "", true)
        for (segment in segments(path)) {
            if (!current.isDir) return null
            current = children(tree, current.id).firstOrNull { it.name == segment } ?: return null
        }
        return current
    }

    private fun requireNote(tree: Uri, path: String): Doc {
        val doc = find(tree, path)
        if (doc == null || doc.isDir) throw FileNotFoundException("$path not found.")
        return doc
    }

    private fun uri(tree: Uri, doc: Doc): Uri = DocumentsContract.buildDocumentUriUsingTree(tree, doc.id)

    fun list(raw: String): List<String> = scan(raw).keys.sorted()

    /**
     * Every note path with a version ("modified:size") that changes when the
     * note does, so the app only reads notes that changed since the last
     * scan. Both come with the folder listing, at no extra cost.
     */
    fun scan(raw: String): Map<String, String> {
        val tree = tree(raw, write = false)
        val out = HashMap<String, String>()
        val ids = HashMap<String, String>()
        val pending = ArrayDeque<Pair<String, String>>()
        pending.add(rootId(tree) to "")
        while (pending.isNotEmpty()) {
            val (id, prefix) = pending.removeFirst()
            for (child in children(tree, id)) {
                if (child.name.startsWith(".")) continue
                val rel = if (prefix.isEmpty()) child.name else "$prefix/${child.name}"
                if (child.isDir) {
                    pending.add(child.id to rel)
                } else {
                    if (isNote(child.name)) out[rel] = "${child.modified}:${child.size}"
                    if (isNote(child.name) || isImage(child.name)) ids[rel] = child.id
                }
            }
        }
        known[raw] = ids
        return out
    }

    /**
     * The text of each of [paths], null for one that cannot be read: one
     * platform call and one permission check for many notes, which is what
     * makes indexing a large folder bearable.
     */
    fun readMany(raw: String, paths: List<String>): List<String?> {
        val tree = tree(raw, write = false)
        return paths.map { path ->
            try {
                decodeUtf8(readRaw(tree, raw, path), path)
            } catch (_: Exception) {
                null
            }
        }
    }

    fun read(raw: String, path: String): String = decodeUtf8(readRaw(raw, path), path)

    private fun readRaw(raw: String, path: String): ByteArray = readRaw(tree(raw, write = false), raw, path)

    private fun readRaw(tree: Uri, raw: String, path: String): ByteArray {
        segments(path)
        known[raw]?.get(path)?.let { id ->
            try {
                return readDoc(DocumentsContract.buildDocumentUriUsingTree(tree, id), path)
            } catch (_: FileNotFoundException) {
                // Gone or moved since the listing: look it up again below.
            }
        }
        return readDoc(uri(tree, requireNote(tree, path)), path)
    }

    private fun readDoc(uri: Uri, path: String): ByteArray {
        val input = resolver.openInputStream(uri) ?: throw IOException("Cannot read $path.")
        return input.use { it.readBytes() }
    }

    fun write(raw: String, path: String, text: String) {
        val tree = tree(raw, write = true)
        writeDoc(uri(tree, requireNote(tree, path)), text)
    }

    /**
     * Keep the displaced document itself, not a read/copy snapshot: a native
     * capture with an open descriptor may still be appending to it. Providers
     * without document rename support fail before any content is replaced.
     */
    fun replaceForSync(raw: String, path: String, expected: String, text: String) {
        val tree = tree(raw, write = true)
        val source = uri(tree, requireNote(tree, path))
        if (decodeUtf8(readDoc(source, path), path) != expected) {
            throw IOException("Note changed during sync; sync again.")
        }
        val name = ".turbonotes-sync-backup-${UUID.randomUUID()}.md"
        val backup = DocumentsContract.renameDocument(resolver, source, name)
            ?: throw IOException("The folder provider cannot retain a sync recovery backup.")
        forget(raw, path)
        try {
            if (displayName(backup) != name) {
                throw IOException("The folder provider did not retain the requested backup name.")
            }
            if (decodeUtf8(readDoc(backup, path), path) != expected) {
                throw IOException("Note changed during sync; sync again.")
            }
            create(raw, path, text)
        } catch (e: Exception) {
            // Use create rather than a renaming overwrite; leave the actual
            // backup document alive for writers that already have it open.
            try {
                if (find(tree, path) == null) {
                    create(raw, path, decodeUtf8(readDoc(backup, path), path))
                }
            } catch (_: Exception) {
                // The recovery backup remains even if restoration fails.
            }
            throw e
        }
    }

    private fun writeDoc(uri: Uri, text: String) = writeBytes(uri, text.toByteArray(Charsets.UTF_8))

    private fun writeBytes(uri: Uri, bytes: ByteArray, newlyCreated: Boolean = false) {
        // "wt" truncates. Plain "w" does not truncate on every provider, which
        // would leave the tail of a longer old file behind a shorter new one.
        val output = resolver.openOutputStream(uri, if (newlyCreated) "wa" else "wt")
            ?: throw IOException("Cannot write the file.")
        output.use { it.write(bytes) }
    }

    fun create(raw: String, path: String, text: String) =
        createNote(raw, path, text.toByteArray(Charsets.UTF_8))

    private fun createNote(raw: String, path: String, bytes: ByteArray) {
        if (!isNote(path)) throw IllegalArgumentException("Notes must end in .md or .markdown.")
        createDocument(raw, path) { writeBytes(it, bytes, newlyCreated = true) }
    }

    /** Reads an image next to the notes (pasted or shared into a note). */
    fun readBytes(raw: String, path: String): ByteArray {
        if (!isImage(path)) throw IllegalArgumentException("Not an image: $path")
        return readRaw(raw, path)
    }

    /** Stores a new image next to the notes; never overwrites. */
    fun createBytes(raw: String, path: String, bytes: ByteArray) {
        if (!isImage(path)) throw IllegalArgumentException("Not an image: $path")
        createDocument(raw, path) { writeBytes(it, bytes, newlyCreated = true) }
    }

    /**
     * Creates the document at [path] (and any missing folders) and fills it
     * with [fill]. Throws [NoteExistsException] rather than overwrite.
     */
    private fun createDocument(raw: String, path: String, fill: (Uri) -> Unit) {
        val tree = tree(raw, write = true)
        val parts = segments(path)
        var parent = Doc(rootId(tree), "", true)
        for (segment in parts.dropLast(1)) {
            val existing = children(tree, parent.id).firstOrNull { it.name == segment }
            parent = when {
                existing == null -> {
                    val created = DocumentsContract.createDocument(
                        resolver, uri(tree, parent), Document.MIME_TYPE_DIR, segment,
                    ) ?: throw IOException("Cannot create folder $segment.")
                    Doc(DocumentsContract.getDocumentId(created), segment, true)
                }
                existing.isDir -> existing
                else -> throw IOException("$segment is a file, not a folder.")
            }
        }
        val name = parts.last()
        if (children(tree, parent.id).any { it.name == name }) throw NoteExistsException("$path already exists.")
        // octet-stream so the provider keeps the name verbatim instead of
        // appending an extension it derives from the MIME type.
        val created = DocumentsContract.createDocument(
            resolver, uri(tree, parent), "application/octet-stream", name,
        ) ?: throw IOException("Cannot create $path.")
        val actual = displayName(created)
        if (actual != name) {
            try {
                DocumentsContract.deleteDocument(resolver, created)
            } catch (_: Exception) {
                // Report the provider naming error even if cleanup fails.
            }
            throw IOException("The folder's provider named the file $actual instead of $name.")
        }
        // Preserve a partial new document on I/O failure, as the directory
        // store does: another writer may already have appended to it.
        fill(created)
    }

    fun delete(raw: String, path: String) {
        val tree = tree(raw, write = true)
        forget(raw, path)
        if (!DocumentsContract.deleteDocument(resolver, uri(tree, requireNote(tree, path)))) {
            throw IOException("Cannot delete $path.")
        }
    }

    /**
     * Copy, then delete. Providers differ in whether they support rename and
     * move at all, while create/write/delete work everywhere notes can be
     * edited. The target is written completely, byte for byte, before the
     * source goes; if the source cannot go, the copy goes instead.
     */
    fun rename(raw: String, from: String, to: String) {
        createNote(raw, to, readRaw(raw, from))
        try {
            delete(raw, from)
        } catch (e: Exception) {
            try {
                delete(raw, to)
            } catch (_: Exception) {
                // Two copies are better than none; report the first failure.
            }
            throw e
        }
    }

    private fun displayName(uri: Uri): String {
        resolver.query(uri, arrayOf(Document.COLUMN_DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) return it.getString(0) ?: ""
        }
        throw IOException("The document provider returned no file name.")
    }

    private fun isImage(name: String): Boolean {
        val lower = name.lowercase()
        return listOf(".png", ".jpg", ".jpeg", ".gif", ".webp").any { lower.endsWith(it) }
    }

    private fun isNote(name: String): Boolean {
        val lower = name.lowercase()
        return lower.endsWith(".md") || lower.endsWith(".markdown")
    }
}
