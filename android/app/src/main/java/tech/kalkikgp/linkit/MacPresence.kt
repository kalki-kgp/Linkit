package tech.kalkikgp.linkit

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

object MacPresence {
    private val _lastSeenMillis = MutableStateFlow<Long?>(null)
    val lastSeenMillis: StateFlow<Long?> = _lastSeenMillis

    fun touch(now: Long = System.currentTimeMillis()) {
        _lastSeenMillis.value = now
    }

    fun reset() {
        _lastSeenMillis.value = null
    }
}
