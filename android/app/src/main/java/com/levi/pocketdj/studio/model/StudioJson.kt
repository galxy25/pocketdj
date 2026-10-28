package com.levi.pocketdj.studio.model

import kotlin.math.floor
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive

/**
 * Lenient JSON accessors that reproduce the iOS `try? c.decode(T.self, forKey:) ?? default`
 * semantics exactly: a missing key, an explicit null, or a value of the wrong type all read as
 * "absent" (null) — never an exception — so a future/hand-edited document degrades field by
 * field. (kotlinx's `coerceInputValues` would not give per-field + per-element isolation for the
 * nested list shapes, hence the explicit tree reads.)
 */
internal fun JsonObject.str(key: String): String? =
    (this[key] as? JsonPrimitive)?.takeIf { it.isString }?.content

internal fun JsonObject.bool(key: String): Boolean? {
    val p = this[key] as? JsonPrimitive ?: return null
    if (p is JsonNull || p.isString) return null
    return when (p.content) {
        "true" -> true
        "false" -> false
        else -> null
    }
}

private fun JsonPrimitive.asLongOrNull(): Long? {
    if (this is JsonNull || isString) return null
    content.toLongOrNull()?.let { return it }
    val d = content.toDoubleOrNull() ?: return null
    return if (d.isFinite() && floor(d) == d && kotlin.math.abs(d) < 9.0e18) d.toLong() else null
}

internal fun JsonObject.long(key: String): Long? = (this[key] as? JsonPrimitive)?.asLongOrNull()

internal fun JsonObject.int(key: String): Int? =
    long(key)?.takeIf { it in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong() }?.toInt()

internal fun JsonObject.double(key: String): Double? {
    val p = this[key] as? JsonPrimitive ?: return null
    if (p is JsonNull || p.isString) return null
    return p.content.toDoubleOrNull()?.takeIf { it.isFinite() }
}

internal fun JsonObject.obj(key: String): JsonObject? = this[key] as? JsonObject

/**
 * `[StudioLossyBox<T>]` + compactMap: decode each element on its own, dropping the ones that fail.
 * Returns null when the key is absent / not an array (the whole-array `try?` failing → caller default).
 */
internal fun <T> JsonObject.lossyList(key: String, decode: (JsonObject) -> T?): List<T>? {
    val arr = this[key] as? JsonArray ?: return null
    return arr.mapNotNull { el -> (el as? JsonObject)?.let { runCatching { decode(it) }.getOrNull() } }
}

/** `[Bool]` all-or-nothing (a single non-bool element fails the whole array, like Foundation). */
internal fun JsonObject.boolList(key: String): List<Boolean>? {
    val arr = this[key] as? JsonArray ?: return null
    val out = ArrayList<Boolean>(arr.size)
    for (el in arr) {
        val p = el as? JsonPrimitive ?: return null
        if (p is JsonNull || p.isString) return null
        out += when (p.content) { "true" -> true; "false" -> false; else -> return null }
    }
    return out
}

/** `[Int]` all-or-nothing. */
internal fun JsonObject.intList(key: String): List<Int>? {
    val arr = this[key] as? JsonArray ?: return null
    val out = ArrayList<Int>(arr.size)
    for (el in arr) {
        val l = (el as? JsonPrimitive)?.asLongOrNull() ?: return null
        if (l !in Int.MIN_VALUE.toLong()..Int.MAX_VALUE.toLong()) return null
        out += l.toInt()
    }
    return out
}

/** `[String: String]` all-or-nothing. */
internal fun JsonObject.stringMap(key: String): Map<String, String>? {
    val o = this[key] as? JsonObject ?: return null
    val out = LinkedHashMap<String, String>(o.size)
    for ((k, v) in o) {
        val p = v as? JsonPrimitive ?: return null
        if (!p.isString) return null
        out[k] = p.content
    }
    return out
}

/** Swift `JSONEncoder` writes an integral Double as `120`, not `120.0` — match it. */
internal fun jsonNum(d: Double): JsonPrimitive =
    if (d.isFinite() && floor(d) == d && kotlin.math.abs(d) < 1.0e15) JsonPrimitive(d.toLong()) else JsonPrimitive(d)

internal fun jsonBools(xs: List<Boolean>): JsonArray = JsonArray(xs.map { JsonPrimitive(it) })
internal fun jsonInts(xs: List<Int>): JsonArray = JsonArray(xs.map { JsonPrimitive(it) })

/** Build a JSON object, skipping null values (Swift `encodeIfPresent`). */
internal fun jsonObj(vararg pairs: Pair<String, JsonElement?>): JsonObject =
    JsonObject(pairs.mapNotNull { (k, v) -> v?.let { k to it } }.toMap(LinkedHashMap()))

internal fun jsonStr(s: String?): JsonElement? = s?.let { JsonPrimitive(it) }
