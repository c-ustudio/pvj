package com.pocketvj

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.util.Log
import org.godotengine.godot.Godot
import org.godotengine.godot.plugin.GodotPlugin
import org.godotengine.godot.plugin.SignalInfo
import org.godotengine.godot.plugin.UsedByGodot
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.channels.FileChannel
import java.util.concurrent.Executors
import java.util.zip.CRC32
import java.util.zip.Inflater
import java.util.zip.InflaterInputStream
import java.util.zip.ZipInputStream

/**
 * VJMIX storage (both tiers) — Play-compliant access to the performer's clips
 * without MANAGE_EXTERNAL_STORAGE or READ_MEDIA_*: the Storage Access Framework.
 *
 *   (legacy, beta1/beta2: a persisted tree grant the performer linked once)
 *   listMedia(tree)         the tree's videos as JSON — the tree AND its direct
 *                           sub-folders (one level; "folder" names which)
 *   folderStamp(tree)       a cheap change stamp of the tree, for a rescan on resume
 *   playablePath(doc)       a PATH GoZen/FFmpeg can open (see below)
 *   copyToCache(doc, capMb) the fallback: a local copy, LRU-capped
 *   pickImage(destPath)     one image, copied into app storage (mask images)
 *   pickImport*() / planTreeCopy / runImport   the import jobs: everything the
 *                           performer brings in is COPIED into filesDir/clips
 *                           (layout 2, docs/STORAGE_REWORK_PLAN.md) — see below
 *
 * GoZen hands a path string to avformat_open_input, so a content:// URI is not
 * directly playable. playablePath() opens the document read-only, KEEPS the
 * ParcelFileDescriptor, and answers "/proc/self/fd/N": FFmpeg's file protocol
 * open()s that magic link, which the kernel resolves to the same open file.
 * ⚠️ MEASURED 2026-09-29, Pixel 8 / Android 17 / ExternalStorageProvider: that
 * re-open is REFUSED (EACCES) — the fd is fine, the path to it is not ours. So
 * in practice clips play from copyToCache(): an LRU-capped copy under
 * cache/clipcache (~4 ms/MB measured), filled ahead of time by prefetch() so a
 * cue is a cache hit. playablePath() is still asked first, once per session,
 * in case another provider or Android version allows it.
 *
 * Every call is SYNCHRONOUS and cheap except the copies, which run on one
 * worker and report by signal. Signals are emitted from that worker; Godot
 * queues them onto the main thread.
 */
class StoragePlugin(godot: Godot) : GodotPlugin(godot) {

    private val TAG = "VJMIXStorage"
    private val REQ_IMAGE = 0x5A03
    private val PREFS = "vjmix_storage"
    private val KEY_TREE = "tree_uri"

    private val io = Executors.newSingleThreadExecutor()
    private val prefetchIo = Executors.newSingleThreadExecutor()   // never queues an import behind it
    @Volatile private var prefetchGen = 0
    private val openFds = HashMap<String, ParcelFileDescriptor>()   // document uri → open fd
    private var imageDest: String = ""       // absolute file path

    override fun getPluginName(): String = "VJMIXStorage"

    override fun getPluginSignals(): Set<SignalInfo> = setOf(
        SignalInfo("image_picked", String::class.java),                        // local path, "" = cancelled
        SignalInfo("prefetch_done", Int::class.javaObjectType, Int::class.javaObjectType), // copied, MB cached
        // Import jobs (layout 2): job id, JSON. Bytes are Long — an Int overflows at 2 GB.
        SignalInfo("import_planned", Int::class.javaObjectType, String::class.java),
        SignalInfo("import_job_progress", Int::class.javaObjectType, String::class.java, Int::class.javaObjectType,
            Int::class.javaObjectType, Long::class.javaObjectType, Long::class.javaObjectType), // job, name, i, n, bytes done, total (-1 unknown)
        SignalInfo("import_finished", Int::class.javaObjectType, String::class.java),
        SignalInfo("storage_report", String::class.java),                       // JSON, see storageReport()
        SignalInfo("setup_done", String::class.java, String::class.java),       // "save"/"restore", "ok:<n>"/"cancelled"/"error:…"
    )

    /** "versionName (versionCode)" of this build, for the About rows. */
    @UsedByGodot
    fun appVersion(): String {
        val act = activity ?: return ""
        return try {
            val pi = act.packageManager.getPackageInfo(act.packageName, 0)
            val code = if (Build.VERSION.SDK_INT >= 28) pi.longVersionCode else @Suppress("DEPRECATION") pi.versionCode.toLong()
            "${pi.versionName} ($code)"
        } catch (e: Exception) { "" }
    }

    private fun prefs() = activity!!.getSharedPreferences(PREFS, Activity.MODE_PRIVATE)

    // ── Folder (tree) ─────────────────────────────────────────────────────────

    /** The persisted tree, or "" when none is set or its grant was revoked. */
    @UsedByGodot
    fun getFolderUri(): String {
        val act = activity ?: return ""
        val s = prefs().getString(KEY_TREE, "") ?: ""
        if (s.isEmpty()) return ""
        val granted = act.contentResolver.persistedUriPermissions.any {
            it.uri.toString() == s && it.isReadPermission
        }
        return if (granted) s else ""
    }

    /** Forget the folder (and release its grant). */
    @UsedByGodot
    fun clearFolder() {
        val act = activity ?: return
        val s = prefs().getString(KEY_TREE, "") ?: ""
        if (s.isNotEmpty()) {
            try {
                act.contentResolver.releasePersistableUriPermission(Uri.parse(s),
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            } catch (e: SecurityException) { /* already gone */ }
        }
        prefs().edit().remove(KEY_TREE).apply()
        closeAll()
    }

    /** Display name of a tree's root ("PVJ"), for the UI and the virtual dir. */
    @UsedByGodot
    fun getFolderLabel(treeUri: String): String {
        if (treeUri.isEmpty()) return ""
        return try {
            val t = Uri.parse(treeUri)
            val doc = DocumentsContract.buildDocumentUriUsingTree(t, DocumentsContract.getTreeDocumentId(t))
            queryName(doc) ?: DocumentsContract.getTreeDocumentId(t).substringAfterLast(':').substringAfterLast('/')
        } catch (e: Exception) { "" }
    }

    /**
     * The tree's direct children that are video, as a JSON array of
     * {name, document_uri, size, mtime, mime}. On any failure an OBJECT,
     * {"error": "…"}: a deleted folder that keeps its grant must read as
     * "unreachable", never as an empty folder (the migration would otherwise
     * "copy 0 clips" and release the grant — STORAGE_REWORK_PLAN §E1).
     */
    @UsedByGodot
    fun listMedia(treeUri: String): String {
        val out = JSONArray()
        if (activity == null || treeUri.isEmpty()) return JSONObject().put("error", "no folder").toString()
        try {
            val t = Uri.parse(treeUri)
            val subs = ArrayList<Pair<String, String>>()   // (document id, display name)
            if (!listInto(t, DocumentsContract.getTreeDocumentId(t), "", out, subs))
                return JSONObject().put("error", "folder not listable").toString()
            // One level down: the tree's direct sub-folders (a starter pack that
            // unzipped into its own folder). Deeper levels are ignored.
            for ((id, name) in subs) listInto(t, id, name, out, null)
        } catch (e: Exception) {
            Log.w(TAG, "listMedia failed: $e")
            return JSONObject().put("error", e.javaClass.simpleName).toString()
        }
        return out.toString()
    }

    /** The videos directly under `docId` into `out`, tagged with `folder`;
     *  non-hidden sub-folders into `subs` when it is not null. False when the
     *  provider gave no cursor (the folder is gone). */
    private fun listInto(t: Uri, docId: String, folder: String, out: JSONArray,
                         subs: ArrayList<Pair<String, String>>?): Boolean {
        val act = activity ?: return false
        val kids = DocumentsContract.buildChildDocumentsUriUsingTree(t, docId)
        val cols = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED)
        val c = act.contentResolver.query(kids, cols, null, null, null) ?: return false
        c.use {
            while (c.moveToNext()) {
                val mime = c.getString(2) ?: ""
                val name = c.getString(1) ?: continue
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    if (subs != null && !name.startsWith(".")) subs.add(Pair(c.getString(0), name))
                    continue
                }
                if (!isVideo(mime, name)) continue
                out.put(JSONObject()
                    .put("name", name)
                    .put("folder", folder)
                    .put("document_uri", DocumentsContract.buildDocumentUriUsingTree(t, c.getString(0)).toString())
                    .put("size", if (c.isNull(3)) -1L else c.getLong(3))
                    .put("mtime", if (c.isNull(4)) 0L else c.getLong(4) / 1000L)
                    .put("mime", mime))
            }
        }
        return true
    }

    /**
     * A cheap stamp that changes when the tree's contents do: the folder's own
     * last-modified, plus each direct sub-folder's, plus the child count. One
     * query of the top level — no recursion into the files. "" when unknown.
     * (On the external storage provider a directory's mtime moves when a file
     * is added to or removed from it — a replaced file of the same name does
     * not; RESCAN covers that.)
     */
    @UsedByGodot
    fun folderStamp(treeUri: String): String {
        val act = activity ?: return ""
        if (treeUri.isEmpty()) return ""
        return try {
            val t = Uri.parse(treeUri)
            val self = DocumentsContract.buildDocumentUriUsingTree(t, DocumentsContract.getTreeDocumentId(t))
            var stamp = 0L
            act.contentResolver.query(self, arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { c ->
                if (c.moveToFirst() && !c.isNull(0)) stamp = c.getLong(0)
            }
            val kids = DocumentsContract.buildChildDocumentsUriUsingTree(t, DocumentsContract.getTreeDocumentId(t))
            var n = 0
            var subs = 0L
            act.contentResolver.query(kids, arrayOf(DocumentsContract.Document.COLUMN_MIME_TYPE,
                DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)?.use { c ->
                while (c.moveToNext()) {
                    n++
                    if (c.getString(0) == DocumentsContract.Document.MIME_TYPE_DIR && !c.isNull(1)) subs += c.getLong(1)
                }
            }
            "$stamp|$subs|$n"
        } catch (e: Exception) { "" }
    }

    // ── Playback access ───────────────────────────────────────────────────────

    /** Opens (once) and returns the fd number, -1 on failure. */
    @UsedByGodot
    fun openFd(documentUri: String): Int {
        synchronized(openFds) {
            openFds[documentUri]?.let { return it.fd }
            val act = activity ?: return -1
            return try {
                val pfd = act.contentResolver.openFileDescriptor(Uri.parse(documentUri), "r") ?: return -1
                openFds[documentUri] = pfd
                pfd.fd
            } catch (e: Exception) {
                Log.w(TAG, "openFd failed for $documentUri: $e")
                -1
            }
        }
    }

    /**
     * "/proc/self/fd/N" for the document, or "" if it cannot be opened OR the
     * magic link cannot be re-opened. The probe is the same open(2) FFmpeg's
     * file protocol will make, so "" here means "use copyToCache", decided
     * before GoZen fails asynchronously on a worker thread.
     */
    @UsedByGodot
    fun playablePath(documentUri: String): String {
        val fd = openFd(documentUri)
        if (fd < 0) return ""
        val p = "/proc/self/fd/$fd"
        return try {
            java.io.FileInputStream(p).use { it.channel.position(0) }
            p
        } catch (e: Exception) {
            // MEASURED on the Pixel 8 (Android 17), ExternalStorageProvider:
            // EACCES. The fd is useless to a path-only consumer, so do not hold it.
            Log.w(TAG, "re-open of $p refused ($e) — caller should copy")
            closeFd(documentUri)
            ""
        }
    }

    @UsedByGodot
    fun closeFd(documentUri: String) {
        synchronized(openFds) {
            try { openFds.remove(documentUri)?.close() } catch (e: Exception) { }
        }
    }

    @UsedByGodot
    fun closeAll() {
        synchronized(openFds) {
            for (p in openFds.values) try { p.close() } catch (e: Exception) { }
            openFds.clear()
        }
    }

    /**
     * The fallback: a local copy under cache/clipcache, named by a hash of the
     * uri, evicting least-recently-USED copies (mtime is touched on every hit)
     * until the total fits capMb. SYNCHRONOUS — call it off the main thread or
     * accept the stall. Returns the absolute path, "" on failure.
     */
    @UsedByGodot
    fun copyToCache(documentUri: String, capMb: Int): String {
        val act = activity ?: return ""
        val f = cacheFile(documentUri) ?: return ""
        // Per-FILE lock: two copies of one file never share a .part, but a
        // main-thread miss never waits behind the prefetch copying another one.
        synchronized(f.absolutePath.intern()) {
            if (f.isFile && f.length() > 0) {
                f.setLastModified(System.currentTimeMillis())
                return f.absolutePath
            }
            return try {
                val tmp = File(f.parentFile, f.name + ".part")
                act.contentResolver.openInputStream(Uri.parse(documentUri))?.use { input ->
                    tmp.outputStream().use { input.copyTo(it, 1 shl 20) }
                } ?: return ""
                tmp.renameTo(f)
                evict(f.parentFile!!, capMb.toLong() * 1024L * 1024L, keep = f)
                f.absolutePath
            } catch (e: Exception) {
                Log.w(TAG, "copyToCache failed for $documentUri: $e")
                ""
            }
        }
    }

    /** The cached copy's path if it already exists (touching it as used), else "". */
    @UsedByGodot
    fun cachedPath(documentUri: String): String {
        val f = cacheFile(documentUri) ?: return ""
        if (!f.isFile || f.length() <= 0) return ""
        f.setLastModified(System.currentTimeMillis())
        return f.absolutePath
    }

    /**
     * Copies the given documents (JSON array of uris, in priority order) into
     * the cache on the worker, skipping ones already there and stopping once
     * the cap is reached — so the deck's cues become cache HITS instead of a
     * copy on the main thread. Emits prefetch_done(copied, total_mb).
     */
    @UsedByGodot
    fun prefetch(urisJson: String, capMb: Int) {
        val uris = try { JSONArray(urisJson) } catch (e: Exception) { return }
        val gen = ++prefetchGen
        prefetchIo.execute {
            var copied = 0
            var budget = capMb.toLong() * 1024L * 1024L
            for (k in 0 until uris.length()) {
                if (gen != prefetchGen) return@execute    // a newer scan superseded this one
                val u = uris.optString(k)
                val f = cacheFile(u) ?: continue
                val size = if (f.isFile) f.length() else querySize(Uri.parse(u))
                if (size in 1..budget) budget -= size else break
                if (!f.isFile && copyToCache(u, capMb).isNotEmpty()) copied++
            }
            emitSignal("prefetch_done", copied, ((capMb.toLong() * 1024L * 1024L - budget) shr 20).toInt())
        }
    }

    private fun cacheFile(documentUri: String): File? {
        val act = activity ?: return null
        val dir = File(act.cacheDir, "clipcache").apply { mkdirs() }
        val name = Uri.parse(documentUri).lastPathSegment?.substringAfterLast('/') ?: "clip"
        return File(dir, "%08x_%s".format(documentUri.hashCode(), name.replace(Regex("[^A-Za-z0-9._-]"), "_")))
    }

    private fun querySize(u: Uri): Long = try {
        activity!!.contentResolver.query(u, arrayOf(DocumentsContract.Document.COLUMN_SIZE),
            null, null, null)?.use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getLong(0) else -1L } ?: -1L
    } catch (e: Exception) { -1L }

    private fun evict(dir: File, capBytes: Long, keep: File) {
        val files = dir.listFiles()?.filter { it.isFile && !it.name.endsWith(".part") } ?: return
        var total = files.sumOf { it.length() }
        for (f in files.sortedBy { it.lastModified() }) {
            if (total <= capBytes) break
            if (f == keep) continue
            total -= f.length()
            f.delete()
        }
    }

    /** Deletes a document (needs the tree's write grant). */
    @UsedByGodot
    fun deleteDocument(documentUri: String): Boolean {
        val act = activity ?: return false
        closeFd(documentUri)
        return try {
            DocumentsContract.deleteDocument(act.contentResolver, Uri.parse(documentUri))
        } catch (e: Exception) {
            Log.w(TAG, "deleteDocument failed: $e"); false
        }
    }

    // ── Zip reading (IMPORT PACK, see the import jobs below) ──────────────────

    private class PackEntry(val name: String, val method: Int, val csize: Long,
                            val usize: Long, val crc: Long, val offset: Long)

    private class CancelledException : Exception("cancelled")

    // The zip's central directory, read from the END of a seekable file: every
    // entry's name, sizes, CRC and local-header offset up front (so n is known
    // and nothing is read twice). Zip64 (> 4 GB or > 65535 entries) is refused
    // (null → the streaming fallback). java.util.zip.ZipFile wants a File path,
    // which a content:// document does not have.
    private fun readCentralDirectory(ch: FileChannel): List<PackEntry>? {
        val size = ch.size()
        if (size < 22) return null
        val tailLen = minOf(size, 22L + 65535L).toInt()
        val tail = ByteBuffer.allocate(tailLen).order(ByteOrder.LITTLE_ENDIAN)
        readFully(ch, tail, size - tailLen)
        var eocd = -1
        var i = tailLen - 22
        while (i >= 0) { if (tail.getInt(i) == 0x06054b50) { eocd = i; break }; i-- }
        if (eocd < 0) return null
        val count = tail.getShort(eocd + 10).toInt() and 0xffff
        val cdSize = tail.getInt(eocd + 12).toLong() and 0xffffffffL
        val cdOff = tail.getInt(eocd + 16).toLong() and 0xffffffffL
        if (count == 0xffff || cdSize == 0xffffffffL || cdOff == 0xffffffffL) return null
        val cd = ByteBuffer.allocate(cdSize.toInt()).order(ByteOrder.LITTLE_ENDIAN)
        readFully(ch, cd, cdOff)
        val out = ArrayList<PackEntry>(count)
        var p = 0
        repeat(count) {
            if (p + 46 > cd.limit() || cd.getInt(p) != 0x02014b50) return null
            val method = cd.getShort(p + 10).toInt() and 0xffff
            val crc = cd.getInt(p + 16).toLong() and 0xffffffffL
            val csize = cd.getInt(p + 20).toLong() and 0xffffffffL
            val usize = cd.getInt(p + 24).toLong() and 0xffffffffL
            val nlen = cd.getShort(p + 28).toInt() and 0xffff
            val elen = cd.getShort(p + 30).toInt() and 0xffff
            val clen = cd.getShort(p + 32).toInt() and 0xffff
            val lho = cd.getInt(p + 42).toLong() and 0xffffffffL
            if (csize == 0xffffffffL || usize == 0xffffffffL || lho == 0xffffffffL) return null
            val nameBytes = ByteArray(nlen)
            for (k in 0 until nlen) nameBytes[k] = cd.get(p + 46 + k)
            out.add(PackEntry(String(nameBytes, Charsets.UTF_8), method, csize, usize, crc, lho))
            p += 46 + nlen + elen + clen
        }
        return out
    }

    private fun readFully(ch: FileChannel, buf: ByteBuffer, at: Long) {
        var pos = at
        while (buf.hasRemaining()) {
            val n = ch.read(buf, pos)
            if (n < 0) throw Exception("zip truncated")
            pos += n
        }
        buf.flip()
    }

    /** The entry's data as a stream: stored bytes, or inflated. */
    private fun entryStream(ch: FileChannel, e: PackEntry): InputStream {
        val lh = ByteBuffer.allocate(30).order(ByteOrder.LITTLE_ENDIAN)
        readFully(ch, lh, e.offset)
        if (lh.getInt(0) != 0x04034b50) throw Exception("bad local header for ${e.name}")
        val nlen = lh.getShort(26).toInt() and 0xffff
        val elen = lh.getShort(28).toInt() and 0xffff
        val raw = ChannelRange(ch, e.offset + 30 + nlen + elen, e.csize)
        return when (e.method) {
            0 -> raw
            8 -> InflaterInputStream(raw, Inflater(true), 1 shl 16)
            else -> throw Exception("unsupported compression ${e.method} on ${e.name}")
        }
    }

    /** A read-only window of a channel, by positional reads (no shared position). */
    private class ChannelRange(val ch: FileChannel, val start: Long, val len: Long) : InputStream() {
        private var pos = 0L
        override fun read(): Int {
            val b = ByteArray(1)
            return if (read(b, 0, 1) == 1) b[0].toInt() and 0xff else -1
        }
        override fun read(b: ByteArray, off: Int, n: Int): Int {
            if (pos >= len) return -1
            val want = minOf(n.toLong(), len - pos).toInt()
            val got = ch.read(ByteBuffer.wrap(b, off, want), start + pos)
            if (got <= 0) return -1
            pos += got
            return got
        }
    }

    /** One image → copied to destPath (mask images). Emits image_picked. */
    @UsedByGodot
    fun pickImage(destPath: String) {
        val act = activity ?: return
        imageDest = destPath
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
        }
        act.runOnUiThread { act.startActivityForResult(i, REQ_IMAGE) }
    }

    /**
     * Where set recordings go: Movies/PVJ Recordings. Since minSdk 30 (Android
     * 11) an app may create media files there by path without any permission,
     * and the system's storage layer puts them in MediaStore — they show in
     * the gallery and survive an uninstall. The debug build (studio.cu.pvj.debug)
     * writes to "PVJ debug Recordings", so test takes never mix with real sets.
     */
    @UsedByGodot
    fun recordingsDir(): String {
        val act = activity ?: return ""
        // NOT created here: SurfaceRecorder mkdirs its set_<stamp>/ folder
        // (parents included) when a recording starts, so nothing appears in
        // the performer's Movies/ until they actually record.
        val name = if (act.packageName.endsWith(".debug")) "PVJ debug Recordings" else "PVJ Recordings"
        return File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES), name).absolutePath
    }

    /**
     * After REC stops: the set's parts handed to the media scanner, so Photos
     * shows them with their final size and duration. stopRecording() only
     * ASKS the recorder to stop — its drain thread writes the last moov a
     * moment later (MEASURED: a scan on the stop call indexed the part
     * without its duration) — so this waits, on a thread of its own, until
     * the parts' sizes hold still for a second (15 s at most), then scans.
     * Nothing here touches the recorder's threads.
     */
    @UsedByGodot
    fun scanMedia(dir: String) {
        val act = activity ?: return
        Thread {
            fun parts() = File(dir).listFiles { f -> f.isFile && f.name.endsWith(".mp4") }?.sortedBy { it.name } ?: emptyList()
            var last = ""
            var still = 0
            val until = android.os.SystemClock.uptimeMillis() + 15000
            while (still < 2 && android.os.SystemClock.uptimeMillis() < until) {
                Thread.sleep(500)
                val now = parts().joinToString { "${it.name}:${it.length()}" }
                if (now == last) still++ else { still = 0; last = now }
            }
            val paths = parts().map { it.absolutePath }
            if (paths.isEmpty()) return@Thread
            android.media.MediaScannerConnection.scanFile(act, paths.toTypedArray(),
                Array(paths.size) { "video/mp4" }, null)
            Log.i(TAG, "scanMedia: ${paths.size} part(s) in $dir")
        }.start()
    }

    // ── Import jobs: everything into PVJ's own storage (STORAGE_REWORK_PLAN §A/§B) ──
    //
    // The library is filesDir/clips (= user://clips): top-level clips plus ONE
    // level of folders (the clip grid's dir: chips). Every import is a job on
    // jobIo in two steps:
    //   pick → PLAN    import_planned(job, json): what would be copied where,
    //                  the totals and the free space. Nothing written yet.
    //   runImport(job) import_job_progress(job, name, i, n, bytes_done, bytes_total)
    //                  ~4 Hz, then import_finished(job, json).
    // Godot only shows a confirm when the plan does not fit, and only rescans
    // when the job is over: no copy ever runs on the main or render thread.
    //
    //   pickImportFiles()            multi-select videos → top level
    //   pickImportFolder(keep)       a tree (TEMPORARY grant, never persisted):
    //                                keep=false → one chip named after it, its files
    //                                and its sub-folders' files flattened into it;
    //                                keep=true → mirrored (top → top, sub → chip),
    //                                the layout ids depend on (re-import, restore)
    //   pickImportPack()             a .zip → <pack name>/ chip
    //   planTreeCopy(tree)           the legacy linked folder, mirrored, with the
    //                                prefetch cache as a fast local source (§E1)
    //
    // Byte counts are declared Long: Godot silently drops a signal whose argument
    // types don't match, and an Int overflows at 2 GB.

    private val REQ_IMP_FILES = 0x5A05
    private val REQ_IMP_TREE = 0x5A06
    private val REQ_IMP_PACK = 0x5A07
    private val VIDEO_EXTS = setOf("mp4", "mov", "mkv", "webm", "m4v", "avi")
    private val MIME_EXT = mapOf("video/mp4" to "mp4", "video/quicktime" to "mov",
        "video/webm" to "webm", "video/x-matroska" to "mkv", "video/x-m4v" to "m4v")
    private val RECORDINGS_FOLDER = "PVJ Recordings"
    private val OLDER_IMPORTS = "OLDER IMPORTS"      // = Storage.OLDER_IMPORTS
    private val RESERVE_BYTES = 512L shl 20          // the recorder's reserve (pipeline REC_RESERVE)
    private val MAX_PACK_ENTRIES = 10000
    private val MAX_NAME_BYTES = 200

    private val jobIo = Executors.newSingleThreadExecutor()   // imports never queue behind a mask image
    private val jobs = HashMap<Int, ImportJob>()               // planned, not yet run (main + jobIo)
    private var nextJob = 1
    private var pickKeepLayout = false
    @Volatile private var jobBusy = false
    @Volatile private var jobCancel = false
    @Volatile private var fakeFreeMb = -1L                     // debug builds only (T7a)

    private class ImportItem(
        val name: String,            // the source's display name (for messages)
        var target: String,          // path relative to clips/ ("" = not copied)
        var size: Long,              // -1 = unknown until copied
        var action: String,          // "copy", "skip" (already in PVJ), "fail"
        var reason: String = "",
        val src: Uri? = null,        // a document
        val cache: File? = null,     // a local copy to read instead (clipcache)
        val entry: PackEntry? = null, // a seekable zip's entry
        val displace: Boolean = false // mirror: an existing other file at `target` moves to OLDER IMPORTS
    )

    private class ImportJob(val id: Int, val kind: String, val folder: String) {
        val items = ArrayList<ImportItem>()
        var zip: Uri? = null
        var streamed = false         // a zip that can't be seeked: planned while it runs
        var notAClip = 0             // files that are not video (packs, folders)
        var junk = 0                 // hidden / __MACOSX / unsafe zip entries
        var tooDeep = 0              // folders below the one level a library keeps
        var error = ""
    }

    private fun clipsRoot(): File = File(activity!!.filesDir, "clips").apply { mkdirs() }

    /** Free bytes where clips live (filesDir), before the reserve. */
    @UsedByGodot
    fun freeBytes(): Long {
        if (fakeFreeMb >= 0) return fakeFreeMb shl 20
        val act = activity ?: return -1L
        return try { android.os.StatFs(act.filesDir.path).availableBytes } catch (e: Exception) { -1L }
    }

    /** Debug builds only: pretend the phone has `mb` free (-1 = real). For the low-storage test. */
    @UsedByGodot
    fun setFakeFreeMb(mb: Int): Boolean {
        val act = activity ?: return false
        if ((act.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) == 0) return false
        fakeFreeMb = mb.toLong()
        Log.i(TAG, "fake free space: ${if (mb < 0) "off" else "$mb MB"}")
        return true
    }

    @UsedByGodot
    fun importBusy(): Boolean = jobBusy

    /**
     * LIB ▸ Storage…: what the library and the cache hold, measured on a
     * thread of its own (never behind an import) → storage_report(json):
     * {top_n, top_bytes, folders:[{name, n, bytes}], free, cache_total,
     * cache_thumbs, cache_demo, cache_clips, files_total}. Bytes, not disk
     * blocks. files_total is all of filesDir (clips included): the panel's
     * OTHER is files_total minus the clips — settings, sequences, masks,
     * Godot's shader cache.
     */
    @UsedByGodot
    fun storageReport() {
        val act = activity ?: return
        Thread {
            val o = JSONObject()
            try {
                var topN = 0
                var topB = 0L
                val folders = JSONArray()
                clipsRoot().listFiles()?.sortedBy { it.name.lowercase() }?.forEach { f ->
                    if (f.isFile && isClipFile(f.name)) { topN++; topB += f.length() }
                    else if (f.isDirectory && !f.name.startsWith(".")) {
                        var n = 0
                        var b = 0L
                        f.listFiles()?.forEach { g -> if (g.isFile && isClipFile(g.name)) { n++; b += g.length() } }
                        folders.put(JSONObject().put("name", f.name).put("n", n).put("bytes", b))
                    }
                }
                val cache = act.cacheDir
                o.put("top_n", topN).put("top_bytes", topB).put("folders", folders).put("free", freeBytes())
                    .put("cache_total", du(cache)).put("cache_thumbs", du(File(cache, "thumbs")))
                    .put("cache_demo", du(File(cache, "demo_stage"))).put("cache_clips", du(File(cache, "clipcache")))
                    .put("files_total", du(act.filesDir))
            } catch (e: Exception) {
                Log.w(TAG, "storageReport failed: $e")
                o.put("error", e.javaClass.simpleName)
            }
            emitSignal("storage_report", o.toString())
        }.start()
    }

    private fun du(f: File): Long = if (f.isFile) f.length() else (f.listFiles()?.sumOf { du(it) } ?: 0L)

    private fun isClipFile(name: String) = !name.startsWith(".") && name.substringAfterLast('.', "").lowercase() in VIDEO_EXTS

    @UsedByGodot
    fun pickImportFiles() = startPicker(REQ_IMP_FILES, Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = "video/*"
        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("video/*"))
        putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
    })

    @UsedByGodot
    fun pickImportFolder(keepLayout: Boolean) {
        pickKeepLayout = keepLayout
        // The picker's own grant only: nothing resumes a job after a process
        // death, and releasing a persisted grant could revoke a legacy user's
        // linked folder if they pick the same tree.
        startPicker(REQ_IMP_TREE, Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            if (Build.VERSION.SDK_INT >= 26) {
                putExtra(DocumentsContract.EXTRA_INITIAL_URI, DocumentsContract.buildDocumentUri(
                    "com.android.externalstorage.documents", "primary:" + Environment.DIRECTORY_MOVIES))
            }
        })
    }

    @UsedByGodot
    fun pickImportPack() = startPicker(REQ_IMP_PACK, Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
        addCategory(Intent.CATEGORY_OPENABLE)
        type = "*/*"
        putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip",
            "application/x-zip-compressed", "application/octet-stream"))
    })

    private fun startPicker(req: Int, i: Intent) {
        val act = activity ?: return
        if (jobBusy) { emitSignal("import_planned", -1, JSONObject().put("error", "busy").toString()); return }
        act.runOnUiThread { act.startActivityForResult(i, req) }
    }

    /** The legacy linked folder, mirrored into the library (COPY CLIPS INTO PVJ, §E1). */
    @UsedByGodot
    fun planTreeCopy(treeUri: String) {
        if (jobBusy) { emitSignal("import_planned", -1, JSONObject().put("error", "busy").toString()); return }
        jobIo.execute {
            val job = newJob("mirror", "")
            try {
                val t = Uri.parse(treeUri)
                planTree(job, t, DocumentsContract.getTreeDocumentId(t), keepLayout = true, cached = true)
            } catch (e: Exception) {
                Log.w(TAG, "planTreeCopy failed: $e")
                job.error = "folder unreachable"
            }
            emitPlan(job)
        }
    }

    private fun onImportPicked(req: Int, resultCode: Int, data: Intent?) {
        if (resultCode != Activity.RESULT_OK || data == null) {
            emitSignal("import_planned", 0, JSONObject().put("cancelled", true).toString()); return
        }
        val keep = pickKeepLayout
        jobIo.execute {
            val job: ImportJob = try {
                when (req) {
                    REQ_IMP_FILES -> {
                        val uris = ArrayList<Uri>()
                        data.clipData?.let { cd -> for (k in 0 until cd.itemCount) uris.add(cd.getItemAt(k).uri) }
                        if (uris.isEmpty()) data.data?.let { uris.add(it) }
                        newJob("files", "").also { planFiles(it, uris) }
                    }
                    REQ_IMP_TREE -> {
                        val t = data.data!!
                        val rootId = DocumentsContract.getTreeDocumentId(t)
                        val label = queryName(DocumentsContract.buildDocumentUriUsingTree(t, rootId))
                            ?: rootId.substringAfterLast(':').substringAfterLast('/')
                        val chip = if (keep) "" else safeName(label, "FOLDER")
                        newJob(if (keep) "mirror" else "folder", chip).also {
                            planTree(it, t, rootId, keepLayout = keep, cached = false)
                        }
                    }
                    else -> {
                        val u = data.data!!
                        val label = (queryName(u) ?: "pack").removeSuffix(".zip").removeSuffix(".ZIP")
                        newJob("pack", safeName(label, "PACK")).also { planPack(it, u) }
                    }
                }
            } catch (e: Exception) {
                Log.w(TAG, "import plan failed: $e")
                newJob("files", "").also { it.error = e.message ?: e.javaClass.simpleName }
            }
            emitPlan(job)
        }
    }

    private fun newJob(kind: String, folder: String): ImportJob {
        synchronized(jobs) {
            val j = ImportJob(nextJob++, kind, folder)
            jobs.clear()                 // only the latest plan can run
            jobs[j.id] = j
            return j
        }
    }

    private fun emitPlan(job: ImportJob) {
        var need = 0L
        var unknown = 0
        var copies = 0
        val items = JSONArray()
        for (it in job.items) {
            if (it.action == "copy") { copies++; if (it.size >= 0) need += it.size else unknown++ }
            items.put(JSONObject().put("name", it.name).put("target", it.target).put("size", it.size)
                .put("action", it.action).put("reason", it.reason))
        }
        val free = freeBytes()
        val o = JSONObject()
            .put("job", job.id).put("kind", job.kind).put("folder", job.folder)
            .put("items", items).put("copies", copies).put("bytes", need).put("unknown_sizes", unknown)
            .put("free", free).put("reserve", RESERVE_BYTES)
            .put("fits", free < 0 || need <= free - RESERVE_BYTES)
            .put("streamed", job.streamed).put("not_a_clip", job.notAClip).put("junk", job.junk)
            .put("too_deep", job.tooDeep).put("error", job.error)
        Log.i(TAG, "import plan #${job.id} ${job.kind} '${job.folder}': $copies to copy, ${need shr 20} MB, " +
            "${job.items.size - copies} not copied, free ${free shr 20} MB${if (job.error != "") ", error ${job.error}" else ""}")
        emitSignal("import_planned", job.id, o.toString())
    }

    /** Drops a plan the performer declined. */
    @UsedByGodot
    fun discardImport(job: Int) { synchronized(jobs) { jobs.remove(job) } }

    // ── Planning ──────────────────────────────────────────────────────────────

    /** name → (folder, size) of every clip already in the library (top + one level). */
    private class LibIndex(root: File) {
        val byName = HashMap<String, ArrayList<Pair<String, Long>>>()
        init {
            root.listFiles()?.forEach { f ->
                if (f.isFile) add(f.name, "", f.length())
                else if (f.isDirectory && !f.name.startsWith(".")) {
                    f.listFiles()?.forEach { g -> if (g.isFile) add(g.name, f.name, g.length()) }
                }
            }
        }
        fun add(name: String, folder: String, size: Long) {
            if (name.endsWith(".part")) return
            byName.getOrPut(name) { ArrayList() }.add(Pair(folder, size))
        }
        /** The folder holding a clip of this name AND size, null when none does. */
        fun sameClip(name: String, size: Long): String? =
            if (size < 0) null else byName[name]?.firstOrNull { it.second == size }?.first
        fun has(folder: String, name: String) = byName[name]?.any { it.first == folder } == true
        fun sizeAt(folder: String, name: String): Long? = byName[name]?.firstOrNull { it.first == folder }?.second
    }

    /** One planned copy: library-wide dedupe by name + size, "name (2).ext" past a
     *  same-name different-size clip in the target folder, or (mirror) exact rel. */
    private fun planOne(job: ImportJob, lib: LibIndex, name: String, folder: String, size: Long,
                        mirror: Boolean, src: Uri? = null, cache: File? = null, entry: PackEntry? = null) {
        if (mirror) {
            // Ids are hash(rel path): only the very same rel counts as present,
            // and the folder's clip must land at ITS rel even when another file
            // already sits there (a demo clip of the same name): that one moves
            // to OLDER IMPORTS when the copy is done, instead of the folder's
            // clip becoming "name (2)" with an id nothing knows.
            val have = lib.sizeAt(folder, name)
            if (have != null && size >= 0 && have == size) {
                job.items.add(ImportItem(name, folder.joinRel(name), size, "skip", "ALREADY IN PVJ"))
                return
            }
            if (have != null) {
                job.items.add(ImportItem(name, folder.joinRel(name), size, "copy", "", src, cache, entry, displace = true))
                return
            }
        } else {
            val where = lib.sameClip(name, size)
            if (where != null) {
                job.items.add(ImportItem(name, where.joinRel(name), size, "skip",
                    "ALREADY IN PVJ (${if (where == "") "TOP" else where})"))
                return
            }
        }
        var target = name
        if (lib.has(folder, name)) {
            val stem = name.substringBeforeLast('.')
            val ext = name.substringAfterLast('.', "")
            var n = 2
            while (true) {
                val cand = if (ext.isEmpty()) "$stem ($n)" else "$stem ($n).$ext"
                if (!lib.has(folder, cand)) { target = cand; break }
                n++
            }
        }
        lib.add(target, folder, size)      // later items in this batch see it
        job.items.add(ImportItem(name, folder.joinRel(target), size, "copy",
            if (target != name) "RENAMED" else "", src, cache, entry))
    }

    private fun String.joinRel(name: String) = if (this == "") name else "$this/$name"

    private fun planFiles(job: ImportJob, uris: List<Uri>) {
        val lib = LibIndex(clipsRoot())
        val cr = activity!!.contentResolver
        for (u in uris) {
            var name: String? = null
            var size = -1L
            try {
                cr.query(u, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME,
                    android.provider.OpenableColumns.SIZE), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        name = c.getString(0)
                        if (!c.isNull(1)) size = c.getLong(1)
                    }
                }
            } catch (e: Exception) { Log.w(TAG, "query $u failed: $e") }
            val shown = name ?: (u.lastPathSegment ?: "clip")
            val clip = clipName(shown, cr.getType(u) ?: "")
            if (clip == null) { job.items.add(ImportItem(shown, "", size, "fail", "UNSUPPORTED TYPE")); continue }
            planOne(job, lib, clip, "", size, mirror = false, src = u)
        }
    }

    /**
     * A tree: keepLayout=false → every video into job.folder (the tree's files
     * and its sub-folders' files, flattened); keepLayout=true → mirrored. Deeper
     * folders are counted, never walked; "PVJ Recordings" and hidden folders are
     * always skipped. cached=true reads a clip from cache/clipcache when the
     * prefetch already holds a copy of the right size (the legacy folder).
     */
    private fun planTree(job: ImportJob, t: Uri, rootId: String, keepLayout: Boolean, cached: Boolean) {
        if (cached) prefetchGen++            // a running prefetch stops after its current file
        val lib = LibIndex(clipsRoot())
        val subs = ArrayList<Pair<String, String>>()
        if (!treeChildren(t, rootId, job, lib, if (keepLayout) "" else job.folder, keepLayout, cached, subs))
            throw Exception("folder unreachable")
        for ((id, name) in subs) {
            val deeper = ArrayList<Pair<String, String>>()
            val folder = if (keepLayout) safeName(name, "FOLDER") else job.folder
            treeChildren(t, id, job, lib, folder, keepLayout, cached, deeper)
            job.tooDeep += deeper.size
        }
    }

    /** Plans the videos directly under docId; collects its sub-folders. False if it can't be listed. */
    private fun treeChildren(t: Uri, docId: String, job: ImportJob, lib: LibIndex, folder: String,
                             mirror: Boolean, cached: Boolean, subs: ArrayList<Pair<String, String>>): Boolean {
        val cr = activity!!.contentResolver
        val kids = DocumentsContract.buildChildDocumentsUriUsingTree(t, docId)
        val cols = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE)
        val c = cr.query(kids, cols, null, null, null) ?: return false
        c.use {
            while (c.moveToNext()) {
                val name = c.getString(1) ?: continue
                val mime = c.getString(2) ?: ""
                if (name.startsWith(".")) continue
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    if (name != RECORDINGS_FOLDER) subs.add(Pair(c.getString(0), name))
                    continue
                }
                if (!isVideo(mime, name)) { job.notAClip++; continue }
                // A mirror copies the library the old folder WAS: the legacy scan
                // listed known extensions only, so anything else was never a clip
                // there (and must not count as a failed copy that blocks the switch).
                if (mirror && name.substringAfterLast('.', "").lowercase() !in VIDEO_EXTS) { job.notAClip++; continue }
                val clip = clipName(name, mime)
                val size = if (c.isNull(3)) -1L else c.getLong(3)
                if (clip == null) { job.items.add(ImportItem(name, "", size, "fail", "UNSUPPORTED TYPE")); continue }
                val doc = DocumentsContract.buildDocumentUriUsingTree(t, c.getString(0))
                // The prefetch named its copy after this exact uri string (listInto).
                val hit = if (cached) cacheFile(doc.toString())?.takeIf { it.isFile && it.length() == size } else null
                planOne(job, lib, clip, folder, size, mirror, src = doc, cache = hit)
            }
        }
        return true
    }

    private fun planPack(job: ImportJob, u: Uri) {
        job.zip = u
        val cr = activity!!.contentResolver
        val entries = try {
            cr.openFileDescriptor(u, "r")?.use { fd ->
                readCentralDirectory(java.io.FileInputStream(fd.fileDescriptor).channel)
            }
        } catch (e: Exception) { null }
        if (entries == null) { job.streamed = true; return }     // planned entry by entry while it runs
        if (entries.size > MAX_PACK_ENTRIES) throw Exception("too many entries (${entries.size})")
        val lib = LibIndex(clipsRoot())
        for (e in entries) {
            val name = when (val n = zipEntryName(e.name)) {
                null -> { if (!e.name.endsWith("/")) job.junk++; continue }
                "" -> { job.notAClip++; continue }
                else -> n
            }
            planOne(job, lib, name, job.folder, e.usize, mirror = false, entry = e)
        }
    }

    /**
     * A zip entry's clip name: null for a directory or anything unsafe or hidden
     * (absolute, drive letter, control characters, a "."-segment, __MACOSX),
     * "" for a file that is not a clip, else the last segment (split on / AND
     * \ — zip-slip), sanitized. Never a path: entries are flattened.
     */
    private fun zipEntryName(raw: String): String? {
        if (raw.endsWith("/") || raw.endsWith("\\")) return null
        if (raw.startsWith("/") || raw.startsWith("\\") || Regex("^[A-Za-z]:").containsMatchIn(raw)) return null
        if (raw.any { it.code < 0x20 || it.code == 0x7f }) return null
        val segs = raw.split('/', '\\').filter { it != "" && it != "." }
        if (segs.isEmpty() || segs.last() == "..") return null
        if (segs.any { it != ".." && (it.startsWith(".") || it == "__MACOSX") }) return null
        val last = segs.last()
        val ext = last.substringAfterLast('.', "").lowercase()
        if (ext !in VIDEO_EXTS) return ""
        return safeName(last, "clip.$ext")
    }

    /** The clip's file name, or null when it is not a type the library lists:
     *  a known extension as is, else one taken from the MIME type (an
     *  extension-less "video/mp4" becomes ".mp4"). */
    private fun clipName(display: String, mime: String): String? {
        val safe = safeName(display, "clip")
        if (safe.substringAfterLast('.', "").lowercase() in VIDEO_EXTS) return safe
        val ext = MIME_EXT[mime.lowercase()] ?: return null
        return safeName("$safe.$ext", "clip.$ext")
    }

    /** A name that is safe as ONE path segment: no / \ : * ? " < > | or control
     *  characters, no leading ".", never "." or "..", at most 200 UTF-8 bytes
     *  (the stem is cut, the extension kept). */
    private fun safeName(raw: String, fallback: String): String {
        var s = raw.map { ch -> if (ch.code < 0x20 || ch.code == 0x7f || ch in "/\\:*?\"<>|") '_' else ch }
            .joinToString("").trim()
        while (s.startsWith(".")) s = s.substring(1)
        if (s.isEmpty() || s == "..") s = fallback
        if (s.toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES) {
            val ext = s.substringAfterLast('.', "")
            val tail = if (ext.isNotEmpty() && ext.length <= 8) ".$ext" else ""
            var stem = s.removeSuffix(tail)
            while ((stem + tail).toByteArray(Charsets.UTF_8).size > MAX_NAME_BYTES) stem = stem.dropLast(1)
            s = stem + tail
        }
        return s
    }

    // ── Running ───────────────────────────────────────────────────────────────

    /**
     * Runs a planned job on jobIo. fitOnly: copy only what fits in the free
     * space (minus the reserve), in plan order (IMPORT WHAT FITS). Emits
     * import_job_progress ~4 Hz and import_finished(job, json) at the end:
     * {imported, duplicates, renamed, failed:[{name, reason}], warnings:[{name,
     * reason}], files:[rel], cancelled, stopped, bytes, ...}.
     */
    @UsedByGodot
    fun runImport(job: Int, fitOnly: Boolean): Boolean {
        val j = synchronized(jobs) { jobs.remove(job) } ?: return false
        if (jobBusy) return false
        jobBusy = true
        jobCancel = false
        jobIo.execute {
            val res = JobResult(j)
            try {
                if (j.streamed) runStreamedPack(j, res) else runItems(j, res, fitOnly)
            } catch (e: CancelledException) {
                res.cancelled = true
            } catch (e: Exception) {
                Log.w(TAG, "import #${j.id} failed: $e")
                res.stopped = e.message ?: e.javaClass.simpleName
            } finally {
                jobBusy = false
            }
            Log.i(TAG, "import #${j.id} done: ${res.imported} imported, ${res.dups} already, " +
                "${res.failed.length()} failed, ${res.bytes shr 20} MB${if (res.cancelled) ", CANCELLED" else ""}" +
                (if (res.stopped != "") ", stopped: ${res.stopped}" else ""))
            emitSignal("import_finished", j.id, res.json().toString())
        }
        return true
    }

    /** Stops the running import after the current chunk; that file's .part is deleted. */
    @UsedByGodot
    fun cancelImport() { jobCancel = true }

    private class JobResult(val job: ImportJob) {
        var imported = 0
        var dups = 0
        var renamed = 0
        var bytes = 0L
        var cancelled = false
        var stopped = ""                  // why the batch stopped early ("no space", …)
        val failed = JSONArray()
        val warnings = JSONArray()
        val files = JSONArray()
        val displaced = JSONArray()       // rels whose old file moved to OLDER IMPORTS (their thumbnails are stale)
        var notAClip = job.notAClip
        var junk = job.junk
        fun fail(name: String, reason: String) { failed.put(JSONObject().put("name", name).put("reason", reason)) }
        fun json(): JSONObject = JSONObject()
            .put("job", job.id).put("kind", job.kind).put("folder", job.folder)
            .put("imported", imported).put("duplicates", dups).put("renamed", renamed)
            .put("failed", failed).put("warnings", warnings).put("files", files).put("displaced", displaced)
            .put("cancelled", cancelled).put("stopped", stopped).put("bytes", bytes)
            .put("not_a_clip", notAClip).put("junk", junk).put("too_deep", job.tooDeep)
    }

    private class NoSpaceException : Exception("no space")

    /** Progress for the whole job, throttled to ~4 Hz (the last one always goes). */
    private inner class Progress(val job: Int, val n: Int, val total: Long) {
        var done = 0L
        private var last = 0L
        fun tick(name: String, i: Int, force: Boolean = false) {
            val now = android.os.SystemClock.uptimeMillis()
            if (!force && now - last < 250) return
            last = now
            emitSignal("import_job_progress", job, name, i, n, done, total)
        }
    }

    private fun runItems(j: ImportJob, res: JobResult, fitOnly: Boolean) {
        val copies = j.items.filter { it.action == "copy" }
        for (it in j.items) {
            if (it.action == "skip") res.dups++
            else if (it.action == "fail") res.fail(it.name, it.reason)
        }
        var budget = if (fitOnly) freeBytes() - RESERVE_BYTES else Long.MAX_VALUE
        val total = copies.sumOf { if (it.size > 0) it.size else 0L }
        val prog = Progress(j.id, copies.size, if (copies.any { it.size < 0 }) -1L else total)
        val cr = activity!!.contentResolver
        var zipFd: ParcelFileDescriptor? = null
        try {
            if (j.kind == "pack") zipFd = cr.openFileDescriptor(j.zip!!, "r") ?: throw Exception("cannot open the zip")
            val ch = zipFd?.let { java.io.FileInputStream(it.fileDescriptor).channel }
            for ((k, it) in copies.withIndex()) {
                if (jobCancel) throw CancelledException()
                if (fitOnly && it.size >= 0 && it.size > budget) { res.fail(it.name, "NO SPACE"); continue }
                prog.tick(it.name, k + 1, force = true)
                val ok = try {
                    val input: InputStream = when {
                        it.entry != null -> entryStream(ch!!, it.entry)
                        it.cache != null -> it.cache.inputStream()
                        else -> cr.openInputStream(it.src!!) ?: throw Exception("cannot open")
                    }
                    copyClip(input, it, prog, k + 1, it.entry?.crc ?: -1L, if (it.entry != null) it.size else -1L, res)
                } catch (e: CancelledException) { throw e
                } catch (e: NoSpaceException) { res.fail(it.name, "NO SPACE"); res.stopped = "no space"; break
                } catch (e: Exception) {
                    Log.w(TAG, "import of ${it.name} failed: $e")
                    res.fail(it.name, failReason(e)); false
                }
                if (ok) {
                    if (it.size > 0) budget -= it.size
                    if (it.reason == "RENAMED") res.renamed++
                }
            }
        } finally {
            try { zipFd?.close() } catch (e: Exception) { }
        }
        prog.tick("", copies.size, force = true)
    }

    private fun failReason(e: Exception): String {
        val m = (e.message ?: "").lowercase()
        return when {
            "crc" in m -> "DAMAGED IN THE ZIP"
            "larger than" in m -> "DAMAGED IN THE ZIP"
            "outside" in m -> "UNSAFE NAME"
            "network" in m || "timeout" in m || "connection" in m -> "DOWNLOAD FAILED"
            else -> "COPY FAILED"
        }
    }

    /**
     * input → clips/<target>.part → fsync → rename → probe. True when the clip
     * stays in the library. Throws NoSpaceException on ENOSPC (the batch
     * stops), CancelledException on cancel; the .part is always gone after.
     */
    private fun copyClip(input: InputStream, it: ImportItem, prog: Progress, i: Int, crc: Long, limit: Long,
                         res: JobResult): Boolean {
        val root = clipsRoot()
        var dst = File(root, it.target)
        dst.parentFile?.mkdirs()
        if (!contained(root, dst)) { input.close(); throw Exception("outside the library: ${it.target}") }
        val part = File(dst.parentFile, "." + dst.name + ".part")
        var written = 0L
        try {
            input.use { ins ->
                java.io.FileOutputStream(part).use { fos ->
                    if (it.size > 0) allocate(fos, it.size)
                    val sum = if (crc >= 0) CRC32() else null
                    val buf = ByteArray(1 shl 20)
                    while (true) {
                        if (jobCancel) throw CancelledException()
                        val n = ins.read(buf)
                        if (n < 0) break
                        if (limit >= 0 && written + n > limit) throw Exception("entry larger than declared")
                        try { fos.write(buf, 0, n) } catch (e: java.io.IOException) { throw spaceOr(e) }
                        sum?.update(buf, 0, n)
                        written += n
                        prog.done += n
                        prog.tick(it.name, i)
                    }
                    if (sum != null && sum.value != crc) throw Exception("CRC mismatch")
                    fos.channel.truncate(written)       // allocate() may have extended it
                    fos.flush()
                    fos.fd.sync()
                }
            }
            // An unknown size (some cloud providers) is only known now: dedupe late.
            if (it.size < 0) {
                it.size = written
                val lib = LibIndex(root)
                val where = lib.sameClip(it.name, written)
                if (where != null) { part.delete(); res.dups++; return false }
            }
            if (dst.exists()) {
                if (it.displace) {
                    val older = File(root, OLDER_IMPORTS).apply { mkdirs() }
                    var moved = File(older, dst.name)
                    if (moved.exists()) moved = freeName(moved)
                    if (!dst.renameTo(moved)) throw Exception("could not move ${dst.name} aside")
                    res.displaced.put(dst.relativeTo(root).path)
                    Log.i(TAG, "mirror: ${dst.relativeTo(root).path} was another file — moved to $OLDER_IMPORTS/${moved.name}")
                } else dst = freeName(dst)
            }
            if (!part.renameTo(dst)) throw Exception("rename failed")
        } catch (e: Exception) {
            part.delete()
            throw e
        }
        val rel = dst.relativeTo(root).path
        val probe = probeClip(dst)
        if (probe == "NOT A VIDEO") {
            dst.delete()
            res.fail(it.name, "NOT A VIDEO")
            return false
        }
        if (probe != "") res.warnings.put(JSONObject().put("name", rel).put("reason", probe))
        res.imported++
        res.bytes += written
        res.files.put(rel)
        return true
    }

    /** Reserve the bytes before writing — frees other apps' cache if it has to,
     *  and fails at once instead of at 90 %. */
    private fun allocate(fos: java.io.FileOutputStream, bytes: Long) {
        if (fakeFreeMb >= 0 && bytes > (fakeFreeMb shl 20) - RESERVE_BYTES) throw NoSpaceException()
        val sm = activity!!.getSystemService(android.os.storage.StorageManager::class.java) ?: return
        try { sm.allocateBytes(fos.fd, bytes) } catch (e: java.io.IOException) {
            Log.w(TAG, "allocateBytes($bytes) refused: $e"); throw NoSpaceException()
        }
    }

    private fun spaceOr(e: java.io.IOException): Exception {
        val m = e.message ?: ""
        return if ("ENOSPC" in m || "No space" in m) NoSpaceException() else e
    }

    private fun contained(root: File, f: File): Boolean =
        f.canonicalPath.startsWith(root.canonicalPath + File.separator)

    private fun freeName(f: File): File {
        val stem = f.name.substringBeforeLast('.')
        val ext = f.name.substringAfterLast('.', "")
        var n = 2
        while (true) {
            val c = File(f.parentFile, if (ext.isEmpty()) "$stem ($n)" else "$stem ($n).$ext")
            if (!c.exists()) return c
            n++
        }
    }

    /**
     * "" = fine; "NOT A VIDEO" = no video track (audio-only, empty); a warning
     * like "MAY STUTTER (3840×2160 HEVC)" for clips above 1080p or HEVC 10-bit
     * / AV1. A container MediaExtractor can't parse is KEPT ("") — GoZen's
     * FFmpeg opens more than it does, and the thumbnail pass decides.
     */
    private fun probeClip(f: File): String {
        if (f.length() == 0L) return "NOT A VIDEO"
        val ex = android.media.MediaExtractor()
        try {
            ex.setDataSource(f.path)
            for (k in 0 until ex.trackCount) {
                val fmt = ex.getTrackFormat(k)
                val mime = fmt.getString(android.media.MediaFormat.KEY_MIME) ?: continue
                if (!mime.startsWith("video/")) continue
                val w = if (fmt.containsKey(android.media.MediaFormat.KEY_WIDTH)) fmt.getInteger(android.media.MediaFormat.KEY_WIDTH) else 0
                val h = if (fmt.containsKey(android.media.MediaFormat.KEY_HEIGHT)) fmt.getInteger(android.media.MediaFormat.KEY_HEIGHT) else 0
                val profile = if (fmt.containsKey(android.media.MediaFormat.KEY_PROFILE)) fmt.getInteger(android.media.MediaFormat.KEY_PROFILE) else -1
                val codec = when (mime) {
                    "video/avc" -> "H.264"; "video/hevc" -> "HEVC"; "video/x-vnd.on2.vp9" -> "VP9"
                    "video/av01" -> "AV1"; "video/x-vnd.on2.vp8" -> "VP8"; else -> mime.removePrefix("video/").uppercase()
                }
                val hevc10 = mime == "video/hevc" && profile in setOf(2, 4096, 8192)
                val big = maxOf(w, h) > 1920 || minOf(w, h) > 1080
                return if (big || hevc10 || mime == "video/av01")
                    "MAY STUTTER (${w}×${h} ${codec}${if (hevc10) " 10-BIT" else ""})" else ""
            }
            return "NOT A VIDEO"
        } catch (e: Exception) {
            // MP4 / MOV / M4V: Android's extractor demuxes these whatever the codec,
            // so one it cannot open is not a video at all (a truncated or random
            // file) — and kept, it would hold the deck forever: GoZen reports no
            // failed open, so a cue to it never comes back. MKV / WebM / AVI are
            // kept: GoZen's FFmpeg opens more of those than MediaExtractor does,
            // and the thumbnail pass decides (CAN'T PLAY).
            val ext = f.name.substringAfterLast('.', "").lowercase()
            if (ext in setOf("mp4", "mov", "m4v")) {
                Log.i(TAG, "probe: ${f.name} is not a readable $ext ($e) — NOT A VIDEO")
                return "NOT A VIDEO"
            }
            Log.i(TAG, "probe: ${f.name} unreadable to MediaExtractor ($e) — kept, the thumbnail decides")
            return ""
        } finally {
            ex.release()
        }
    }

    /** A zip that can't be seeked (a cloud stream): each entry is planned and
     *  copied as it comes, front to back. Sizes may be unknown until read. */
    private fun runStreamedPack(j: ImportJob, res: JobResult) {
        val cr = activity!!.contentResolver
        val lib = LibIndex(clipsRoot())
        val prog = Progress(j.id, 0, -1L)
        var count = 0
        var k = 0
        val ins = cr.openInputStream(j.zip!!) ?: throw Exception("cannot read the zip")
        ins.use { ZipInputStream(it).use { z ->
            while (true) {
                if (jobCancel) throw CancelledException()
                val ze = z.nextEntry ?: break
                if (++count > MAX_PACK_ENTRIES) throw Exception("too many entries")
                if (ze.isDirectory) continue
                val name = when (val n = zipEntryName(ze.name)) {
                    null -> { res.junk++; continue }
                    "" -> { res.notAClip++; continue }
                    else -> n
                }
                val before = j.items.size
                planOne(j, lib, name, j.folder, ze.size, mirror = false)
                val item = j.items[before]
                if (item.action == "skip") { res.dups++; continue }
                // Not closing the entry stream: ZipInputStream moves to the next one.
                val entryIn = object : InputStream() {
                    override fun read(): Int = z.read()
                    override fun read(b: ByteArray, off: Int, len: Int): Int = z.read(b, off, len)
                    override fun close() { }
                }
                // A streamed entry with no declared size is capped by the free space.
                val cap = if (ze.size >= 0) ze.size else maxOf(0L, freeBytes() - RESERVE_BYTES)
                try {
                    if (copyClip(entryIn, item, prog, ++k, if (ze.size >= 0 && ze.crc >= 0) ze.crc else -1L, cap, res)
                        && item.reason == "RENAMED") res.renamed++
                } catch (e: NoSpaceException) { res.fail(item.name, "NO SPACE"); res.stopped = "no space"; return
                } catch (e: CancelledException) { throw e
                } catch (e: Exception) {
                    Log.w(TAG, "pack entry ${item.name} failed: $e"); res.fail(item.name, failReason(e))
                }
            }
        } }
        prog.tick("", k, force = true)
    }

    // ── Setup save / restore (STORAGE_REWORK_PLAN §E2, Q8) ──────────────────
    //
    // SAVE SETUP: the small config files + mask images into ONE zip the
    // performer puts where they like (Downloads, Drive) — the way a setup
    // survives an uninstall (sideload → Play with another signing key).
    // RESTORE SETUP: such a zip read back, allowlisted names only, size-capped,
    // into filesDir/restore_stage/; storage.gd moves it into place at the NEXT
    // start, before anything reads it (a running app would save over it).

    private val REQ_SETUP_SAVE = 0x5A08
    private val REQ_SETUP_RESTORE = 0x5A09
    private val SETUP_MARK = "PVJ_SETUP.txt"
    private val SETUP_NAMES = Regex("^(settings\\.cfg|playlist\\.cfg|sequence\\.tres|sequence_b\\.tres|regions\\.cfg|" +
        "warp\\.cfg|calibration\\.cfg|sequences/slot_[1-6]\\.tres|mask_sets/set_[0-9]{1,2}\\.cfg|masks/mask_[0-9]{1,12}\\.png)$")
    private val SETUP_ENTRY_CAP = 32L shl 20
    private val SETUP_TOTAL_CAP = 128L shl 20
    private var setupFiles = JSONArray()

    /** SAVE SETUP…: `filesJson` = [{path (absolute), name (zip entry)}]; the picker names the zip. */
    @UsedByGodot
    fun saveSetup(fileName: String, filesJson: String) {
        val act = activity ?: return
        setupFiles = try { JSONArray(filesJson) } catch (e: Exception) { JSONArray() }
        val i = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/zip"
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        act.runOnUiThread { act.startActivityForResult(i, REQ_SETUP_SAVE) }
    }

    /** RESTORE SETUP…: pick a setup zip; it is staged for the next start. */
    @UsedByGodot
    fun restoreSetup() {
        val act = activity ?: return
        val i = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip",
                "application/x-zip-compressed", "application/octet-stream"))
        }
        act.runOnUiThread { act.startActivityForResult(i, REQ_SETUP_RESTORE) }
    }

    private fun onSetupSaved(resultCode: Int, data: Intent?) {
        val u = data?.data
        if (resultCode != Activity.RESULT_OK || u == null) { emitSignal("setup_done", "save", "cancelled"); return }
        val files = setupFiles
        jobIo.execute {
            val status = try {
                var n = 0
                activity!!.contentResolver.openOutputStream(u, "wt")?.use { os ->
                    java.util.zip.ZipOutputStream(os).use { z ->
                        z.putNextEntry(java.util.zip.ZipEntry(SETUP_MARK))
                        z.write(("PVJ setup\nsaved ${java.util.Date()}\napp ${appVersion()}\n").toByteArray())
                        z.closeEntry()
                        for (k in 0 until files.length()) {
                            val o = files.optJSONObject(k) ?: continue
                            val f = File(o.optString("path"))
                            val name = o.optString("name")
                            if (!f.isFile || !SETUP_NAMES.matches(name)) continue
                            z.putNextEntry(java.util.zip.ZipEntry(name))
                            f.inputStream().use { it.copyTo(z) }
                            z.closeEntry()
                            n++
                        }
                    }
                } ?: throw Exception("no output stream")
                "ok:$n"
            } catch (e: Exception) {
                Log.w(TAG, "saveSetup failed: $e"); "error:${e.message ?: e.javaClass.simpleName}"
            }
            emitSignal("setup_done", "save", status)
        }
    }

    private fun onSetupPicked(resultCode: Int, data: Intent?) {
        val u = data?.data
        if (resultCode != Activity.RESULT_OK || u == null) { emitSignal("setup_done", "restore", "cancelled"); return }
        jobIo.execute {
            val stage = File(activity!!.filesDir, "restore_stage")
            val status = try {
                stage.deleteRecursively()
                stage.mkdirs()
                var n = 0
                var total = 0L
                var marked = false
                activity!!.contentResolver.openInputStream(u)?.use { ins -> ZipInputStream(ins).use { z ->
                    var count = 0
                    while (true) {
                        val e = z.nextEntry ?: break
                        if (++count > 200) throw Exception("not a PVJ setup (too many entries)")
                        if (e.name == SETUP_MARK) { marked = true; continue }
                        if (e.isDirectory || !SETUP_NAMES.matches(e.name)) continue
                        val out = File(stage, e.name)
                        if (!contained(stage, out)) continue
                        out.parentFile?.mkdirs()
                        var got = 0L
                        java.io.FileOutputStream(out).use { o ->
                            val buf = ByteArray(1 shl 16)
                            while (true) {
                                val r = z.read(buf)
                                if (r < 0) break
                                got += r
                                total += r
                                if (got > SETUP_ENTRY_CAP || total > SETUP_TOTAL_CAP) throw Exception("not a PVJ setup (too large)")
                                o.write(buf, 0, r)
                            }
                        }
                        n++
                    }
                } } ?: throw Exception("cannot read the zip")
                if (!marked || n == 0) throw Exception("not a PVJ setup")
                File(stage, ".complete").writeText("$n\n")
                "ok:$n"
            } catch (e: Exception) {
                Log.w(TAG, "restoreSetup failed: $e")
                stage.deleteRecursively()
                "error:${e.message ?: e.javaClass.simpleName}"
            }
            emitSignal("setup_done", "restore", status)
        }
    }

    override fun onMainActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        when (requestCode) {
            REQ_IMAGE -> onImageResult(resultCode, data)
            REQ_IMP_FILES, REQ_IMP_TREE, REQ_IMP_PACK -> onImportPicked(requestCode, resultCode, data)
            REQ_SETUP_SAVE -> onSetupSaved(resultCode, data)
            REQ_SETUP_RESTORE -> onSetupPicked(resultCode, data)
        }
    }

    private fun onImageResult(resultCode: Int, data: Intent?) {
        val u = data?.data
        if (resultCode != Activity.RESULT_OK || u == null || imageDest.isEmpty()) {
            emitSignal("image_picked", ""); return
        }
        val dest = File(imageDest)
        io.execute {
            val ok = try {
                dest.parentFile?.mkdirs()
                activity!!.contentResolver.openInputStream(u)?.use { i -> dest.outputStream().use { i.copyTo(it) } } != null
            } catch (e: Exception) { Log.w(TAG, "image copy failed: $e"); false }
            emitSignal("image_picked", if (ok) dest.absolutePath else "")
        }
    }

    private fun queryName(u: Uri): String? = try {
        activity!!.contentResolver.query(u, arrayOf(DocumentsContract.Document.COLUMN_DISPLAY_NAME),
            null, null, null)?.use { c -> if (c.moveToFirst()) c.getString(0) else null }
    } catch (e: Exception) { null }

    private fun isVideo(mime: String, name: String): Boolean {
        if (mime.startsWith("video/")) return true
        val ext = name.substringAfterLast('.', "").lowercase()
        return ext in setOf("mp4", "mov", "mkv", "webm", "m4v", "avi")
    }
}
