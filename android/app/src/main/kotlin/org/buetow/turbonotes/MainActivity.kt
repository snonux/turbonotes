package org.buetow.turbonotes

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileNotFoundException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

class MainActivity : FlutterActivity() {
    private val storageChannelName = "org.buetow.turbonotes/storage"
    private val safChannelName = "org.buetow.turbonotes/saf"
    private val safNotesChannelName = "org.buetow.turbonotes/saf-notes"
    private val clipboardChannelName = "org.buetow.turbonotes/clipboard"
    private val shareChannelName = "org.buetow.turbonotes/share"
    private val imagesChannelName = "org.buetow.turbonotes/images"
    private val externalChannelName = "org.buetow.turbonotes/external"
    private var externalChannel: MethodChannel? = null
    private val requestLegacyStorage = 4203
    private val requestNoteTree = 4204
    private val requestPickImages = 4205
    private val requestTakePhoto = 4206
    private var pendingStorageResult: MethodChannel.Result? = null
    private var pendingTreeResult: MethodChannel.Result? = null
    private var pendingImageResult: MethodChannel.Result? = null
    private var pendingPhoto: File? = null

    // Document providers can be slow (cloud-backed ones especially), so all
    // note I/O runs off the main thread, one request at a time and in order.
    private var safExecutor: ExecutorService? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        MethodChannel(messenger, storageChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "storageApiLevel" -> result.success(Build.VERSION.SDK_INT)
                "requestStorageAccess" -> requestStorageAccess(result)
                "needsAllFilesAccess" -> result.success(needsAllFilesAccess(call.requireString("path")))
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, safChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickTree" -> pickTree(result)
                "releaseTree" -> releaseTree(call, result)
                else -> result.notImplemented()
            }
        }
        val notes = SafNotes(contentResolver)
        val executor = Executors.newSingleThreadExecutor { task -> Thread(task, "turbonotes-saf") }
        safExecutor = executor
        val main = Handler(Looper.getMainLooper())
        MethodChannel(messenger, safNotesChannelName).setMethodCallHandler { call, result ->
            if (call.method !in setOf("list", "read", "write", "replaceForSync", "create", "delete", "rename", "readBytes", "createBytes")) {
                result.notImplemented()
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val tree = call.requireString("treeUri")
                    val value: Any? = when (call.method) {
                        "list" -> notes.list(tree)
                        "read" -> notes.read(tree, call.requireString("path"))
                        "write" -> notes.write(tree, call.requireString("path"), call.requireString("text"))
                        "replaceForSync" -> notes.replaceForSync(
                            tree, call.requireString("path"), call.requireString("expected"), call.requireString("text"),
                        )
                        "create" -> notes.create(tree, call.requireString("path"), call.requireString("text"))
                        "delete" -> notes.delete(tree, call.requireString("path"))
                        "readBytes" -> notes.readBytes(tree, call.requireString("path"))
                        "createBytes" -> notes.createBytes(
                            tree,
                            call.requireString("path"),
                            call.argument<ByteArray>("bytes") ?: throw IllegalArgumentException("bytes is required."),
                        )
                        else -> notes.rename(tree, call.requireString("from"), call.requireString("to"))
                    }
                    main.post { result.success(if (value is Unit) null else value) }
                } catch (e: IllegalArgumentException) {
                    main.post { result.error("bad_args", e.message, null) }
                } catch (e: SecurityException) {
                    main.post { result.error("access_denied", e.message, null) }
                } catch (e: NoteExistsException) {
                    main.post { result.error("exists", e.message, null) }
                } catch (e: FileNotFoundException) {
                    main.post { result.error("not_found", e.message, null) }
                } catch (e: Exception) {
                    main.post { result.error("io", e.message ?: e.toString(), null) }
                }
            }
        }
        // A text file another app handed over with "Edit" or "Open with".
        val documents = ExternalDocuments(contentResolver)
        val external = MethodChannel(messenger, externalChannelName)
        externalChannel = external
        external.setMethodCallHandler { call, result ->
            if (call.method == "initialDocument") {
                result.success(documents.describe(intent))
                return@setMethodCallHandler
            }
            if (call.method != "read" && call.method != "write") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val uri = call.requireString("uri")
                    val value: Any? = if (call.method == "read") {
                        documents.read(uri)
                    } else {
                        documents.write(uri, call.requireString("text"))
                        null
                    }
                    main.post { result.success(value) }
                } catch (e: SecurityException) {
                    main.post { result.error("access_denied", e.message, null) }
                } catch (e: FileNotFoundException) {
                    main.post { result.error("not_found", e.message, null) }
                } catch (e: Exception) {
                    main.post { result.error("io", e.message ?: e.toString(), null) }
                }
            }
        }
        MethodChannel(messenger, clipboardChannelName).setMethodCallHandler { call, result ->
            if (call.method != "readImage") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            // Read on the main thread (Android only lets the focused app see
            // the clipboard), load the bytes off it.
            val image = clipboardImage()
            if (image == null) {
                result.success(null)
                return@setMethodCallHandler
            }
            executor.execute {
                try {
                    val bytes = contentResolver.openInputStream(image.first)?.use { readLimited(it) }
                    main.post {
                        result.success(bytes?.let { mapOf("bytes" to it, "mime" to image.second) })
                    }
                } catch (e: Exception) {
                    main.post { result.error("io", e.message ?: e.toString(), null) }
                }
            }
        }
        MethodChannel(messenger, imagesChannelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickImages" -> pickImages(result)
                "takePhoto" -> takePhoto(result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(messenger, shareChannelName).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "shareText" -> {
                        share(Intent(Intent.ACTION_SEND).apply {
                            type = "text/plain"
                            putExtra(Intent.EXTRA_TEXT, call.requireString("text"))
                            putExtra(Intent.EXTRA_SUBJECT, call.requireString("subject"))
                        })
                        result.success(null)
                    }
                    "shareFile" -> {
                        val uri = ShareProvider.uriFor(call.requireString("name"))
                        share(Intent(Intent.ACTION_SEND).apply {
                            type = call.requireString("mime")
                            putExtra(Intent.EXTRA_STREAM, uri)
                            putExtra(Intent.EXTRA_SUBJECT, call.requireString("subject"))
                            // The grant reaches the app picked in the chooser
                            // only through the clip data.
                            clipData = ClipData.newRawUri("", uri)
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                        })
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (e: ActivityNotFoundException) {
                result.error("no_app", "No app can receive this.", null)
            } catch (e: IllegalArgumentException) {
                result.error("bad_args", e.message, null)
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        val document = ExternalDocuments(contentResolver).describe(intent) ?: return
        setIntent(intent)
        externalChannel?.invokeMethod("open", document)
    }

    private fun share(intent: Intent) {
        startActivity(Intent.createChooser(intent, null).apply {
            if (intent.clipData != null) addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        })
    }

    /** The first image on the clipboard: its URI and MIME type. */
    private fun clipboardImage(): Pair<Uri, String>? {
        val clipboard = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
        val clip = clipboard.primaryClip ?: return null
        for (i in 0 until clip.itemCount) {
            val uri = clip.getItemAt(i).uri ?: continue
            val mime = contentResolver.getType(uri)
                ?: (0 until clip.description.mimeTypeCount)
                    .map { clip.description.getMimeType(it) }
                    .firstOrNull { it.startsWith("image/") }
                ?: continue
            if (mime.startsWith("image/")) return uri to mime
        }
        return null
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Let writes already handed to the provider finish.
        safExecutor?.shutdown()
        safExecutor = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun pickTree(result: MethodChannel.Result) {
        if (pendingTreeResult != null) {
            result.error("busy", "Another folder dialog is already open.", null)
            return
        }
        pendingTreeResult = result
        try {
            startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION)
            }, requestNoteTree)
        } catch (e: ActivityNotFoundException) {
            pendingTreeResult = null
            result.error("no_picker", "No folder picker is available.", null)
        }
    }

    /** Opens the photo picker (Android 13+) or the system image chooser. */
    private fun pickImages(result: MethodChannel.Result) {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            Intent(MediaStore.ACTION_PICK_IMAGES).apply {
                type = "image/*"
                putExtra(MediaStore.EXTRA_PICK_IMAGES_MAX,
                    minOf(maxPickedImages, MediaStore.getPickImagesMaxLimit()))
            }
        } else {
            Intent(Intent.ACTION_GET_CONTENT).apply {
                type = "image/*"
                addCategory(Intent.CATEGORY_OPENABLE)
                putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            }
        }
        startImageActivity(intent, requestPickImages, result, "No gallery app is available.")
    }

    /** Has the camera app take a photo into an empty file of the app's cache. */
    private fun takePhoto(result: MethodChannel.Result) {
        if (pendingImageResult != null) {
            result.error("busy", "Another image dialog is already open.", null)
            return
        }
        val file: File
        try {
            val dir = ShareProvider.captureDir(this)
            dir.mkdirs()
            // Photos left over from a camera trip the app did not survive.
            dir.listFiles()?.forEach { it.delete() }
            file = File(dir, "photo-${System.currentTimeMillis()}.jpg")
            file.createNewFile()
        } catch (e: Exception) {
            result.error("io", e.message ?: e.toString(), null)
            return
        }
        val uri = ShareProvider.captureUriFor(file)
        val intent = Intent(MediaStore.ACTION_IMAGE_CAPTURE).apply {
            putExtra(MediaStore.EXTRA_OUTPUT, uri)
            // The grant reaches the camera app only through the clip data.
            clipData = ClipData.newRawUri("", uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        pendingPhoto = file
        if (!startImageActivity(intent, requestTakePhoto, result, "No camera app is available.")) {
            pendingPhoto = null
            file.delete()
        }
    }

    private fun startImageActivity(
        intent: Intent,
        requestCode: Int,
        result: MethodChannel.Result,
        missing: String,
    ): Boolean {
        if (pendingImageResult != null) {
            result.error("busy", "Another image dialog is already open.", null)
            return false
        }
        pendingImageResult = result
        try {
            startActivityForResult(intent, requestCode)
            return true
        } catch (e: ActivityNotFoundException) {
            pendingImageResult = null
            result.error("no_app", missing, null)
        } catch (e: SecurityException) {
            pendingImageResult = null
            result.error("access_denied", e.message ?: e.toString(), null)
        }
        return false
    }

    /** Reads what the gallery or camera returned, off the main thread. */
    private fun finishImageRequest(requestCode: Int, resultCode: Int, data: Intent?) {
        val result = pendingImageResult ?: return
        pendingImageResult = null
        val photo = pendingPhoto
        pendingPhoto = null
        val uris = if (requestCode == requestPickImages && resultCode == Activity.RESULT_OK) {
            val clip = data?.clipData
            if (clip != null) (0 until clip.itemCount).mapNotNull { clip.getItemAt(it).uri }
            else listOfNotNull(data?.data)
        } else {
            emptyList()
        }
        val main = Handler(Looper.getMainLooper())
        val work = Runnable {
            try {
                val value: Any? = if (requestCode == requestTakePhoto) {
                    if (resultCode == Activity.RESULT_OK) {
                        photo?.let { readPhoto(it) }
                    } else {
                        photo?.delete()
                        null
                    }
                } else {
                    uris.take(maxPickedImages).map { readImage(contentResolver, it) }
                }
                main.post { result.success(value) }
            } catch (e: Exception) {
                main.post { result.error("io", e.message ?: e.toString(), null) }
            }
        }
        val executor = safExecutor
        if (executor != null) executor.execute(work) else Thread(work).start()
    }

    private fun releaseTree(call: MethodCall, result: MethodChannel.Result) {
        val raw = call.argument<String>("uri")
        if (raw == null) {
            result.error("bad_args", "A folder URI is required.", null)
            return
        }
        try {
            val uri = Uri.parse(raw)
            val grant = contentResolver.persistedUriPermissions.firstOrNull { it.uri == uri }
            if (grant != null) {
                val flags = (if (grant.isReadPermission) Intent.FLAG_GRANT_READ_URI_PERMISSION else 0) or
                    (if (grant.isWritePermission) Intent.FLAG_GRANT_WRITE_URI_PERMISSION else 0)
                contentResolver.releasePersistableUriPermission(uri, flags)
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("access_denied", e.message ?: e.toString(), null)
        }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == requestPickImages || requestCode == requestTakePhoto) {
            finishImageRequest(requestCode, resultCode, data)
            return
        }
        if (requestCode != requestNoteTree) return
        val result = pendingTreeResult ?: return
        pendingTreeResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            result.success(null)
            return
        }
        try {
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            if (flags != (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)) {
                throw SecurityException("The selected folder needs read and write access.")
            }
            val alreadyGranted = contentResolver.persistedUriPermissions.any {
                it.uri == uri && it.isReadPermission && it.isWritePermission
            }
            contentResolver.takePersistableUriPermission(uri, flags)
            try {
                val treeDocument = DocumentsContract.buildDocumentUriUsingTree(
                    uri, DocumentsContract.getTreeDocumentId(uri))
                result.success(mapOf("uri" to uri.toString(), "name" to displayName(treeDocument)))
            } catch (e: Exception) {
                if (!alreadyGranted) contentResolver.releasePersistableUriPermission(uri, flags)
                throw e
            }
        } catch (e: Exception) {
            result.error("access_denied", e.message ?: e.toString(), null)
        }
    }

    private fun displayName(uri: Uri): String {
        try {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val name = cursor.getString(0)
                        if (!name.isNullOrEmpty()) return name
                    }
                }
        } catch (e: Exception) {
            // Fall through to the URI: the name is only a label.
        }
        return uri.lastPathSegment ?: uri.toString()
    }

    // Android 7-10 uses a runtime permission for direct paths in shared storage.
    private fun hasLegacyStoragePermission(): Boolean =
        checkSelfPermission(Manifest.permission.READ_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED &&
            checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED

    /**
     * On Android 11+ an app without All files access can still create its own
     * files in shared folders such as Documents, so a write probe succeeds,
     * but every note another app or a sync tool put there stays invisible.
     * Only the app's own directories work without the permission.
     */
    private fun needsAllFilesAccess(path: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || Environment.isExternalStorageManager()) {
            return false
        }
        val target = File(path).canonicalFile
        if (!target.path.startsWith("/storage/")) return false
        val own = (getExternalFilesDirs(null) + externalCacheDirs + obbDirs)
            .filterNotNull()
            .mapNotNull { it.parentFile?.canonicalFile }
        return own.none { target.startsWith(it) }
    }

    private fun requestStorageAccess(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R) {
            if (hasLegacyStoragePermission()) {
                result.success(null)
            } else if (pendingStorageResult != null) {
                result.error("busy", "A storage permission request is already open.", null)
            } else {
                pendingStorageResult = result
                requestPermissions(
                    arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE),
                    requestLegacyStorage,
                )
            }
            return
        }
        // Android has no runtime dialog for MANAGE_EXTERNAL_STORAGE.
        try {
            startActivity(Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:$packageName"),
            ))
            result.success(null)
        } catch (e: ActivityNotFoundException) {
            result.error("no_settings", "Storage settings are unavailable.", null)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == requestLegacyStorage) {
            pendingStorageResult?.success(null)
            pendingStorageResult = null
        }
    }
}

private fun MethodCall.requireString(key: String): String =
    argument<String>(key) ?: throw IllegalArgumentException("$key is required.")

/** Images larger than this are refused rather than pulled into memory. */
internal const val maxImageBytes = 32 * 1024 * 1024

internal fun readLimited(input: java.io.InputStream): ByteArray {
    val out = java.io.ByteArrayOutputStream()
    val buffer = ByteArray(64 * 1024)
    while (true) {
        val n = input.read(buffer)
        if (n < 0) break
        out.write(buffer, 0, n)
        if (out.size() > maxImageBytes) throw java.io.IOException("The image is larger than 32 MB.")
    }
    return out.toByteArray()
}
