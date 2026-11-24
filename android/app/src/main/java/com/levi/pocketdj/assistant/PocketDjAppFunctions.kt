package com.levi.pocketdj.assistant

import androidx.appfunctions.AppFunctionContext
import androidx.appfunctions.service.AppFunction

class PocketDjAppFunctions {
    /** Probe. */
    @AppFunction(isDescribedByKDoc = true)
    suspend fun probe(appFunctionContext: AppFunctionContext, x: String): String = x
}
