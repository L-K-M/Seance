package com.lkm.seance_app

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "seance/files"
        private const val DIRECTORY_REQUEST = 7341
        private const val PREFERENCES = "seance_file_exports"
        private const val TREE_URI = "export_tree_uri"
    }

    private val copyExecutor: ExecutorService = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val preferences by lazy { getSharedPreferences(PREFERENCES, MODE_PRIVATE) }
    private var pendingDirectoryResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler(::handleFileMethod)
    }

    private fun handleFileMethod(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickExportDirectory" -> pickExportDirectory(result)
            "hasExportDirectoryAccess" -> result.success(hasExportDirectoryAccess())
            "exportFile" -> exportFile(call.arguments, result)
            "releaseExportDirectory" -> {
                releaseExportDirectory()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun pickExportDirectory(result: MethodChannel.Result) {
        if (pendingDirectoryResult != null) {
            result.error(
                "PICK_IN_PROGRESS",
                "An export directory picker is already open.",
                null,
            )
            return
        }

        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                    Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or
                    Intent.FLAG_GRANT_PREFIX_URI_PERMISSION,
            )
        }
        pendingDirectoryResult = result
        try {
            startActivityForResult(intent, DIRECTORY_REQUEST)
        } catch (_: Exception) {
            pendingDirectoryResult = null
            result.error(
                "PICK_FAILED",
                "Android could not open the export directory picker.",
                null,
            )
        }
    }

    @Deprecated("Required by ACTION_OPEN_DOCUMENT_TREE on FlutterActivity")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode != DIRECTORY_REQUEST) {
            super.onActivityResult(requestCode, resultCode, data)
            return
        }

        val result = pendingDirectoryResult ?: return
        pendingDirectoryResult = null
        if (resultCode == Activity.RESULT_CANCELED) {
            result.success(false)
            return
        }
        if (resultCode != Activity.RESULT_OK) {
            result.error(
                "PICK_FAILED",
                "Android did not return an export directory.",
                null,
            )
            return
        }

        val uri = data?.data
        val grantFlags = data?.flags?.and(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        ) ?: 0
        if (
            uri == null ||
            !DocumentsContract.isTreeUri(uri) ||
            grantFlags and Intent.FLAG_GRANT_WRITE_URI_PERMISSION == 0
        ) {
            result.error(
                "PICK_FAILED",
                "The selected provider did not grant write access.",
                null,
            )
            return
        }

        try {
            contentResolver.takePersistableUriPermission(uri, grantFlags)
        } catch (_: Exception) {
            result.error(
                "PICK_FAILED",
                "Android could not retain access to the selected directory.",
                null,
            )
            return
        }

        val previous = savedTreeUri()
        preferences.edit().putString(TREE_URI, uri.toString()).apply()
        if (previous != null && previous != uri) releaseTreePermission(previous)
        result.success(true)
    }

    private fun hasExportDirectoryAccess(): Boolean {
        val uri = savedTreeUri() ?: return false
        return contentResolver.persistedUriPermissions.any { permission ->
            permission.uri == uri && permission.isWritePermission
        }
    }

    private fun releaseExportDirectory() {
        savedTreeUri()?.let(::releaseTreePermission)
        preferences.edit().remove(TREE_URI).apply()
    }

    private fun releaseTreePermission(uri: Uri) {
        val permission = contentResolver.persistedUriPermissions.firstOrNull {
            it.uri == uri
        } ?: return
        var flags = 0
        if (permission.isReadPermission) {
            flags = flags or Intent.FLAG_GRANT_READ_URI_PERMISSION
        }
        if (permission.isWritePermission) {
            flags = flags or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
        }
        if (flags == 0) return
        try {
            contentResolver.releasePersistableUriPermission(uri, flags)
        } catch (_: Exception) {
            // A provider can revoke a grant independently; forgetting it locally
            // still leaves this method in the requested released state.
        }
    }

    private fun savedTreeUri(): Uri? {
        val raw = preferences.getString(TREE_URI, null)
        if (raw.isNullOrBlank()) return null
        return try {
            Uri.parse(raw).takeIf { uri ->
                uri.scheme == "content" && DocumentsContract.isTreeUri(uri)
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun exportFile(arguments: Any?, result: MethodChannel.Result) {
        val values = arguments as? Map<*, *>
        val sourcePath = values?.get("sourcePath") as? String
        val fileName = values?.get("fileName") as? String
        val mimeType = values?.get("mimeType") as? String
        if (
            sourcePath.isNullOrBlank() ||
            fileName.isNullOrBlank() ||
            mimeType.isNullOrBlank() ||
            !isSafeFileName(fileName) ||
            !isSafeMimeType(mimeType)
        ) {
            result.error(
                "INVALID_ARGUMENT",
                "A valid staged file, file name, and MIME type are required.",
                null,
            )
            return
        }

        val source = File(sourcePath)
        if (!source.isFile || !source.canRead() || !isAppLocalFile(source)) {
            result.error(
                "SOURCE_NOT_FOUND",
                "The staged file is no longer available.",
                null,
            )
            return
        }
        val treeUri = savedTreeUri()
        if (treeUri == null || !hasExportDirectoryAccess()) {
            result.error(
                "NO_EXPORT_DIRECTORY",
                "Choose an export directory before exporting files.",
                null,
            )
            return
        }

        try {
            copyExecutor.execute {
                copyToDocument(source, treeUri, fileName, mimeType, result)
            }
        } catch (_: RejectedExecutionException) {
            result.error(
                "EXPORT_FAILED",
                "Android could not start the file export.",
                null,
            )
        }
    }

    private fun copyToDocument(
        source: File,
        treeUri: Uri,
        fileName: String,
        mimeType: String,
        result: MethodChannel.Result,
    ) {
        val input = try {
            FileInputStream(source)
        } catch (_: Exception) {
            postError(
                result,
                "SOURCE_NOT_FOUND",
                "The staged file is no longer available.",
            )
            return
        }

        var documentUri: Uri? = null
        try {
            input.use { sourceStream ->
                val parentUri = DocumentsContract.buildDocumentUriUsingTree(
                    treeUri,
                    DocumentsContract.getTreeDocumentId(treeUri),
                )
                documentUri = DocumentsContract.createDocument(
                    contentResolver,
                    parentUri,
                    mimeType,
                    fileName,
                ) ?: throw IOException("Document provider returned no URI")
                val output = contentResolver.openOutputStream(documentUri!!, "w")
                    ?: throw IOException("Document provider returned no stream")
                output.use { destination ->
                    sourceStream.copyTo(destination, 64 * 1024)
                    destination.flush()
                }
            }
            mainHandler.post { result.success(documentUri.toString()) }
        } catch (_: SecurityException) {
            deletePartialDocument(documentUri)
            if (savedTreeUri() == treeUri) {
                preferences.edit().remove(TREE_URI).apply()
            }
            postError(
                result,
                "NO_EXPORT_DIRECTORY",
                "Access to the export directory was revoked.",
            )
        } catch (_: Exception) {
            deletePartialDocument(documentUri)
            postError(
                result,
                "EXPORT_FAILED",
                "Android could not create or write the exported file.",
            )
        }
    }

    private fun deletePartialDocument(uri: Uri?) {
        if (uri == null) return
        try {
            DocumentsContract.deleteDocument(contentResolver, uri)
        } catch (_: Exception) {
            // Best effort: providers are allowed to reject deletion.
        }
    }

    private fun postError(result: MethodChannel.Result, code: String, message: String) {
        mainHandler.post { result.error(code, message, null) }
    }

    private fun isAppLocalFile(file: File): Boolean {
        val source = try {
            file.canonicalFile
        } catch (_: IOException) {
            return false
        }
        val roots = mutableListOf(cacheDir, filesDir, noBackupFilesDir)
        externalCacheDir?.let(roots::add)
        getExternalFilesDirs(null).filterNotNullTo(roots)
        return roots.any { root ->
            val canonicalRoot = try {
                root.canonicalFile
            } catch (_: IOException) {
                return@any false
            }
            source == canonicalRoot || source.path.startsWith(
                canonicalRoot.path + File.separator,
            )
        }
    }

    private fun isSafeFileName(fileName: String): Boolean =
        fileName.length <= 255 &&
            fileName != "." &&
            fileName != ".." &&
            fileName.none { character ->
                character == '/' ||
                    character == '\\' ||
                    character.code < 32 ||
                    character.code == 127
            }

    private fun isSafeMimeType(mimeType: String): Boolean {
        val separator = mimeType.indexOf('/')
        return separator > 0 &&
            separator < mimeType.lastIndex &&
            separator == mimeType.lastIndexOf('/') &&
            mimeType.none { character -> character.isWhitespace() || character.code < 32 }
    }

    override fun onDestroy() {
        copyExecutor.shutdown()
        super.onDestroy()
    }
}
