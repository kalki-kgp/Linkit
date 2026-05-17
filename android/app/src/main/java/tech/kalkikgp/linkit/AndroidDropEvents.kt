package tech.kalkikgp.linkit

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

object AndroidDropEvents {
    private val _events = MutableSharedFlow<AndroidDropEvent>(extraBufferCapacity = 16)
    val events: SharedFlow<AndroidDropEvent> = _events.asSharedFlow()

    fun publish(event: AndroidDropEvent) {
        _events.tryEmit(event)
    }
}
