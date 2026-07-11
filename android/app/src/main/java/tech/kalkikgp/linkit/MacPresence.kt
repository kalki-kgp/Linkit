package tech.kalkikgp.linkit

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

object MacPresence {
    private val _lastSeenMillis = MutableStateFlow<Long?>(null)
    val lastSeenMillis: StateFlow<Long?> = _lastSeenMillis

    /** The Mac's self-reported feature health, refreshed from each registration response. */
    private val _macFeatures = MutableStateFlow<List<FeatureStatus>>(emptyList())
    val macFeatures: StateFlow<List<FeatureStatus>> = _macFeatures

    fun touch(now: Long = System.currentTimeMillis()) {
        _lastSeenMillis.value = now
    }

    fun setMacFeatures(features: List<FeatureStatus>) {
        if (features.isNotEmpty()) _macFeatures.value = features
    }

    fun reset() {
        _lastSeenMillis.value = null
        _macFeatures.value = emptyList()
    }
}
