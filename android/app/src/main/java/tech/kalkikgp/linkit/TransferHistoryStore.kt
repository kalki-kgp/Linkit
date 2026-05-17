package tech.kalkikgp.linkit

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

data class TransferHistoryEntry(
    val id: String,
    val direction: String,
    val filename: String,
    val size: Long,
    val peerName: String,
    val completedAt: Long,
    val status: String,
    val savedPath: String?,
    val error: String?
) {
    companion object {
        const val DIRECTION_SENT = "sent"
        const val DIRECTION_RECEIVED = "received"
        const val STATUS_COMPLETE = "complete"
        const val STATUS_FAILED = "failed"
        const val STATUS_CANCELED = "canceled"
    }
}

class TransferHistoryStore private constructor(context: Context) {
    private val file: File = File(context.filesDir, "transfer-history.json")
    private val _entries = MutableStateFlow<List<TransferHistoryEntry>>(emptyList())
    val entries: StateFlow<List<TransferHistoryEntry>> = _entries
    private val lock = Any()
    private val persistScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val persistLock = Any()

    init {
        _entries.value = load()
    }

    fun append(entry: TransferHistoryEntry) {
        synchronized(lock) {
            val updated = (listOf(entry) + _entries.value).take(MAX_ENTRIES)
            _entries.value = updated
            persistScope.launch { persist(updated) }
        }
    }

    fun clear() {
        synchronized(lock) {
            _entries.value = emptyList()
            persistScope.launch { runCatching { file.delete() } }
        }
    }

    private fun load(): List<TransferHistoryEntry> {
        if (!file.exists()) return emptyList()
        return runCatching {
            val array = JSONArray(file.readText(Charsets.UTF_8))
            buildList {
                for (i in 0 until array.length()) add(fromJson(array.getJSONObject(i)))
            }
        }.getOrElse {
            Log.w("Linkit", "transfer history load failed", it)
            emptyList()
        }
    }

    private fun persist(list: List<TransferHistoryEntry>) {
        synchronized(persistLock) {
            runCatching {
                val array = JSONArray()
                list.forEach { array.put(toJson(it)) }
                val tmp = File(file.parentFile, "${file.name}.tmp")
                tmp.writeText(array.toString(), Charsets.UTF_8)
                if (!tmp.renameTo(file)) {
                    file.writeText(array.toString(), Charsets.UTF_8)
                    tmp.delete()
                }
            }.onFailure { Log.w("Linkit", "transfer history write failed", it) }
        }
    }

    private fun toJson(entry: TransferHistoryEntry): JSONObject = JSONObject()
        .put("id", entry.id)
        .put("direction", entry.direction)
        .put("filename", entry.filename)
        .put("size", entry.size)
        .put("peerName", entry.peerName)
        .put("completedAt", entry.completedAt)
        .put("status", entry.status)
        .put("savedPath", entry.savedPath ?: JSONObject.NULL)
        .put("error", entry.error ?: JSONObject.NULL)

    private fun fromJson(json: JSONObject): TransferHistoryEntry = TransferHistoryEntry(
        id = json.getString("id"),
        direction = json.getString("direction"),
        filename = json.getString("filename"),
        size = json.getLong("size"),
        peerName = json.optString("peerName"),
        completedAt = json.getLong("completedAt"),
        status = json.getString("status"),
        savedPath = json.nullableString("savedPath"),
        error = json.nullableString("error")
    )

    private fun JSONObject.nullableString(name: String): String? {
        if (!has(name) || isNull(name)) return null
        return optString(name).takeIf { it.isNotBlank() }
    }

    companion object {
        private const val MAX_ENTRIES = 100

        @Volatile private var instance: TransferHistoryStore? = null

        fun get(context: Context): TransferHistoryStore {
            return instance ?: synchronized(this) {
                instance ?: TransferHistoryStore(context.applicationContext).also { instance = it }
            }
        }
    }
}
