package com.levi.pocketdj.data.sync

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/** A `pocketdj://link/<code>` deep link parks its (validated) code here for Settings > Link a device to fill in. */
object LinkDeviceRequests {
    private val _code = MutableStateFlow<String?>(null)
    val code: StateFlow<String?> = _code
    fun request(code: String) { _code.value = code }
    fun consume() { _code.value = null }
}
