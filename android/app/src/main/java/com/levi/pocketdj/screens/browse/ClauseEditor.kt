package com.levi.pocketdj.screens.browse

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.ZoneOffset
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ExperimentalLayoutApi
import androidx.compose.foundation.layout.FlowRow
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.DatePicker
import androidx.compose.material3.DatePickerDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberDatePickerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.unit.dp
import java.text.DateFormat
import java.util.Date

/**
 * Pure reducer behind the clause editor (iOS `FilterSheet.ClauseEditor`). All value edits go
 * through here so the field/op/value invariants are JVM-testable.
 */
object ClauseReducer {

    /** New clause for the "Add filter" button: first field of the kind, its first op. */
    fun newClause(fields: List<Field>): Clause? {
        val f = fields.firstOrNull() ?: return null
        return Clause(f.id, f.ops.first())
    }

    /** Changing the field resets the op to the field's first op and clears every value. */
    fun changeField(c: Clause, fieldId: String): Clause {
        val f = Fields.byId[fieldId] ?: return c
        return c.copy(field = fieldId, op = f.ops.first(), value = "", values = emptySet(), min = null, max = null)
    }

    /** Changing the op keeps the field; values that no longer fit the op shape are dropped. */
    fun changeOp(c: Clause, op: FilterOp): Clause = when (op) {
        FilterOp.EQ, FilterOp.NEQ -> c.copy(op = op, values = emptySet(), min = null, max = null)
        FilterOp.IN_LIST, FilterOp.NOT_IN_LIST -> c.copy(op = op, value = "", min = null, max = null)
        FilterOp.BETWEEN -> c.copy(op = op, value = "", values = emptySet())
    }

    fun toggleValue(c: Clause, v: String): Clause =
        c.copy(values = if (v in c.values) c.values - v else c.values + v)

    /** Comma-separated free-text list -> trimmed, non-empty set (iOS "Comma-separated" field). */
    fun parseCommaList(text: String): Set<String> =
        text.split(',').map { it.trim() }.filter { it.isNotEmpty() }.toSet()

    fun formatCommaList(values: Set<String>): String = values.sorted().joinToString(", ")

    /** Number bound text -> Double? (blank / unparsable -> null, i.e. open bound). */
    fun parseBound(text: String): Double? = text.trim().toDoubleOrNull()

    fun formatBound(v: Double?): String = v?.let { if (it == it.toLong().toDouble()) it.toLong().toString() else it.toString() } ?: ""

    /** Start of the chosen local day, epoch ms (the "From" picker). */
    fun startOfDayMs(pickedMs: Long, zone: ZoneId = ZoneId.systemDefault()): Double =
        Instant.ofEpochMilli(pickedMs).atZone(zone).toLocalDate().atStartOfDay(zone).toInstant().toEpochMilli().toDouble()

    /** End of the chosen local day = start of NEXT day - 1 ms (DST-safe; the "To" picker). */
    fun endOfDayMs(pickedMs: Long, zone: ZoneId = ZoneId.systemDefault()): Double =
        Instant.ofEpochMilli(pickedMs).atZone(zone).toLocalDate().plusDays(1).atStartOfDay(zone)
            .toInstant().toEpochMilli().toDouble() - 1.0

    /** Fields that render date pickers for `between`. */
    fun usesDatePickers(fieldId: String): Boolean = fieldId == "lastPlayedAt" || fieldId == "dateAdded"

    /** Material3 DatePicker reports UTC-midnight millis of the chosen calendar day. */
    fun pickerDay(utcMidnightMs: Long): LocalDate =
        Instant.ofEpochMilli(utcMidnightMs).atZone(ZoneOffset.UTC).toLocalDate()

    fun startOfDayMs(day: LocalDate, zone: ZoneId = ZoneId.systemDefault()): Double =
        day.atStartOfDay(zone).toInstant().toEpochMilli().toDouble()

    fun endOfDayMs(day: LocalDate, zone: ZoneId = ZoneId.systemDefault()): Double =
        day.plusDays(1).atStartOfDay(zone).toInstant().toEpochMilli().toDouble() - 1.0

    /** Epoch-ms clause bound -> the UTC-midnight millis the DatePicker wants as initial selection. */
    fun toPickerMs(boundMs: Double, zone: ZoneId = ZoneId.systemDefault()): Long =
        Instant.ofEpochMilli(boundMs.toLong()).atZone(zone).toLocalDate().atStartOfDay(ZoneOffset.UTC).toInstant().toEpochMilli()
}

/** One clause card: field picker, op picker, value editor, remove. */
@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
fun ClauseEditorRow(
    clause: Clause,
    fields: List<Field>,
    options: (String) -> List<String>,
    onChange: (Clause) -> Unit,
    onRemove: () -> Unit,
) {
    val field = Fields.byId[clause.field] ?: fields.first()
    Column(Modifier.fillMaxWidth()) {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
            PickerButton(
                label = field.label,
                items = fields.map { it.id to it.label },
                tag = "clause-field",
                onPick = { onChange(ClauseReducer.changeField(clause, it)) },
            )
            Spacer(Modifier.width(8.dp))
            PickerButton(
                label = clause.op.label,
                items = field.ops.map { it.id to it.label },
                tag = "clause-op",
                onPick = { id -> FilterOp.byId[id]?.let { onChange(ClauseReducer.changeOp(clause, it)) } },
            )
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onRemove, modifier = Modifier.testTag("remove-clause-${clause.field}")) {
                Icon(Icons.Filled.Delete, contentDescription = "Remove filter")
            }
        }
        Spacer(Modifier.padding(top = 4.dp))
        ValueEditor(clause, field, options, onChange)
    }
}

@Composable
private fun PickerButton(label: String, items: List<Pair<String, String>>, tag: String, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Column {
        OutlinedButton(onClick = { open = true }, modifier = Modifier.testTag(tag)) { Text(label) }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            items.forEach { (id, text) ->
                DropdownMenuItem(text = { Text(text) }, onClick = { open = false; onPick(id) })
            }
        }
    }
}

@OptIn(ExperimentalLayoutApi::class, ExperimentalMaterial3Api::class)
@Composable
private fun ValueEditor(clause: Clause, field: Field, options: (String) -> List<String>, onChange: (Clause) -> Unit) {
    if (field.kind == FieldKind.BOOL) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Is explicit", modifier = Modifier.weight(1f))
            Switch(
                checked = clause.value == "true",
                onCheckedChange = { onChange(clause.copy(value = if (it) "true" else "false")) },
            )
        }
        return
    }
    val opts = if (field.hasOptions) options(field.id) else emptyList()
    when (clause.op) {
        FilterOp.BETWEEN ->
            if (ClauseReducer.usesDatePickers(field.id)) DateRangeEditor(clause, onChange)
            else Row(verticalAlignment = Alignment.CenterVertically) {
                BoundField("Min", clause.min, Modifier.weight(1f)) { onChange(clause.copy(min = it)) }
                Text("  \u2013  ", color = MaterialTheme.colorScheme.onSurfaceVariant)
                BoundField("Max", clause.max, Modifier.weight(1f)) { onChange(clause.copy(max = it)) }
            }
        FilterOp.IN_LIST, FilterOp.NOT_IN_LIST ->
            if (field.hasOptions) {
                Text("${field.label} (${clause.values.size})", style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                    opts.forEach { o ->
                        FilterChip(
                            selected = o in clause.values,
                            onClick = { onChange(ClauseReducer.toggleValue(clause, o)) },
                            label = { Text(o) },
                        )
                    }
                }
            } else {
                var text by remember(clause.id) { mutableStateOf(ClauseReducer.formatCommaList(clause.values)) }
                OutlinedTextField(
                    value = text,
                    onValueChange = { text = it; onChange(clause.copy(values = ClauseReducer.parseCommaList(it))) },
                    label = { Text("Comma-separated") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        FilterOp.EQ, FilterOp.NEQ ->
            if (field.hasOptions) {
                PickerButton(
                    label = clause.value.ifEmpty { "\u2014" },
                    items = listOf("" to "\u2014") + opts.map { it to it },
                    tag = "clause-value",
                    onPick = { onChange(clause.copy(value = it)) },
                )
            } else {
                OutlinedTextField(
                    value = clause.value,
                    onValueChange = { onChange(clause.copy(value = it)) },
                    label = { Text("Value") },
                    singleLine = true,
                    keyboardOptions = if (field.numeric) KeyboardOptions(keyboardType = KeyboardType.Number) else KeyboardOptions.Default,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
    }
}

@Composable
private fun BoundField(label: String, value: Double?, modifier: Modifier, onValue: (Double?) -> Unit) {
    var text by remember { mutableStateOf(ClauseReducer.formatBound(value)) }
    OutlinedTextField(
        value = text,
        onValueChange = { text = it; onValue(ClauseReducer.parseBound(it)) },
        label = { Text(label) },
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
        modifier = modifier,
    )
}

/** lastPlayedAt / dateAdded between: From = start of day, To = end of day - 1 ms (inclusive). */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DateRangeEditor(clause: Clause, onChange: (Clause) -> Unit) {
    var picking by remember { mutableStateOf<String?>(null) } // "from" | "to"
    val fmt = remember { DateFormat.getDateInstance(DateFormat.MEDIUM) }
    fun label(ms: Double?, empty: String) = ms?.let { fmt.format(Date(it.toLong())) } ?: empty
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        OutlinedButton(onClick = { picking = "from" }, modifier = Modifier.testTag("daterange-from")) {
            Text("From: ${label(clause.min, "any")}")
        }
        OutlinedButton(onClick = { picking = "to" }, modifier = Modifier.testTag("daterange-to")) {
            Text("To: ${label(clause.max, "any")}")
        }
    }
    if (clause.min != null || clause.max != null) {
        TextButton(
            onClick = { onChange(clause.copy(min = null, max = null)) },
            modifier = Modifier.testTag("daterange-clear"),
        ) { Text("Clear dates") }
    }
    val which = picking
    if (which != null) {
        val initial = (if (which == "from") clause.min else clause.max)?.let(ClauseReducer::toPickerMs)
        val state = rememberDatePickerState(initialSelectedDateMillis = initial)
        DatePickerDialog(
            onDismissRequest = { picking = null },
            confirmButton = {
                TextButton(onClick = {
                    state.selectedDateMillis?.let { ms ->
                        val day = ClauseReducer.pickerDay(ms)
                        onChange(
                            if (which == "from") clause.copy(min = ClauseReducer.startOfDayMs(day))
                            else clause.copy(max = ClauseReducer.endOfDayMs(day)),
                        )
                    }
                    picking = null
                }) { Text("OK") }
            },
            dismissButton = { TextButton(onClick = { picking = null }) { Text("Cancel") } },
        ) { DatePicker(state = state) }
    }
}
