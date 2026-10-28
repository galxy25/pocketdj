package com.levi.pocketdj.studio.score

import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import java.io.ByteArrayOutputStream

/**
 * Draws one laid [ScorePage] onto an android.graphics.Canvas whose coordinates are top-left / y-down page space (iOS `ScoreRenderer`).
 * ONE renderer, two hosts: the Compose editor (via nativeCanvas, scaled) and [ScorePdf] (a PdfDocument page canvas, which records
 * VECTOR ops). Clefs / rests / accidentals are drawn as vector paths, not font glyphs, so no missing-glyph box can land in an export.
 * The sheet is paper-white / black ink in both hosts by design (screen == export).
 */
object ScoreRenderer {
    private fun stroke(width: Float, cap: Paint.Cap = Paint.Cap.ROUND) = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE; color = Color.BLACK; strokeWidth = width; strokeCap = cap
    }
    private fun fill() = Paint(Paint.ANTI_ALIAS_FLAG).apply { style = Paint.Style.FILL; color = Color.BLACK }

    fun draw(page: ScorePage, canvas: Canvas) {
        val bg = Paint().apply { style = Paint.Style.FILL; color = Color.WHITE }
        canvas.drawRect(0f, 0f, page.width, page.height, bg)
        for (g in page.glyphs) draw(g, canvas)
    }

    private fun oval(c: Canvas, cx: Float, cy: Float, rx: Float, ry: Float, paint: Paint) = c.drawOval(RectF(cx - rx, cy - ry, cx + rx, cy + ry), paint)

    private fun draw(g: ScoreGlyph, c: Canvas) {
        when (g) {
            is ScoreGlyph.Line -> c.drawLine(g.from.x, g.from.y, g.to.x, g.to.y, stroke(g.width))
            is ScoreGlyph.NoteHead -> oval(c, g.center.x, g.center.y, g.rx, g.ry, if (g.filled) fill() else stroke(1.1f))
            is ScoreGlyph.Flags -> {
                val dir = if (g.stemUp) 1f else -1f
                val s = g.spacing
                val p = stroke(1.6f)
                for (i in 0 until g.count) {
                    val sx = g.tip.x
                    val sy = g.tip.y + dir * i * 0.7f * s
                    val path = Path()
                    path.moveTo(sx, sy)
                    path.cubicTo(sx + 0.2f * s, sy + dir * 0.5f * s, sx + 0.9f * s, sy + dir * 0.9f * s, sx + 1.0f * s, sy + dir * 1.6f * s)
                    c.drawPath(path, p)
                }
            }
            is ScoreGlyph.Dot -> c.drawCircle(g.center.x, g.center.y, g.radius, fill())
            is ScoreGlyph.Sharp -> {
                val s = g.size; val cx = g.center.x; val cy = g.center.y
                val v = stroke(0.9f)
                for (dx in floatArrayOf(-0.32f * s, 0.32f * s)) c.drawLine(cx + dx, cy - 0.85f * s, cx + dx, cy + 0.85f * s, v)
                val h = stroke(1.5f)
                for (dy in floatArrayOf(-0.27f * s, 0.27f * s)) c.drawLine(cx - 0.72f * s, cy + dy + 0.15f * s, cx + 0.72f * s, cy + dy - 0.15f * s, h)
            }
            is ScoreGlyph.Flat -> {
                val s = g.size; val cx = g.center.x; val cy = g.center.y
                val p = stroke(1.0f)
                c.drawLine(cx - 0.30f * s, cy - 1.15f * s, cx - 0.30f * s, cy + 0.55f * s, p)
                val bowl = Path()
                bowl.moveTo(cx - 0.30f * s, cy - 0.15f * s)
                bowl.quadTo(cx + 0.60f * s, cy + 0.05f * s, cx - 0.30f * s, cy + 0.55f * s)
                c.drawPath(bowl, p)
            }
            is ScoreGlyph.Rest -> drawRest(g.duration, g.center, g.spacing, c)
            is ScoreGlyph.Clef -> if (g.role == StaffRole.TREBLE) drawTreble(g.x, g.topLineY, g.spacing, c) else drawBass(g.x, g.topLineY, g.spacing, c)
            is ScoreGlyph.Text -> {
                val p = Paint(Paint.ANTI_ALIAS_FLAG).apply {
                    color = Color.BLACK; textSize = g.size
                    typeface = Typeface.create(Typeface.SANS_SERIF, if (g.bold) Typeface.BOLD else Typeface.NORMAL)
                }
                c.drawText(g.string, g.at.x, g.at.y, p)
            }
        }
    }

    private fun drawRest(d: NoteDuration, ctr: Pt, s: Float, c: Canvas) {
        val x = ctr.x; val y = ctr.y
        when (d) {
            NoteDuration.WHOLE -> c.drawRect(x - 0.8f * s, y - s, x + 0.8f * s, y - s + 0.45f * s, fill())
            NoteDuration.HALF -> c.drawRect(x - 0.8f * s, y - 0.45f * s, x + 0.8f * s, y, fill())
            NoteDuration.QUARTER -> {
                val path = Path()
                path.moveTo(x - 0.2f * s, y - 1.6f * s)
                path.lineTo(x + 0.5f * s, y - 0.7f * s)
                path.lineTo(x - 0.3f * s, y + 0.1f * s)
                path.cubicTo(x - 0.5f * s, y + 0.7f * s, x + 0.6f * s, y + 0.9f * s, x + 0.4f * s, y + 1.3f * s)
                c.drawPath(path, stroke(1.8f))
            }
            NoteDuration.EIGHTH, NoteDuration.SIXTEENTH -> {
                val bottom = if (d == NoteDuration.SIXTEENTH) 1.4f * s else 1.0f * s
                c.drawLine(x + 0.45f * s, y - 0.9f * s, x - 0.4f * s, y + bottom, stroke(1.4f))
                val r = 0.22f * s
                c.drawCircle(x - 0.15f * s, y - 0.55f * s, r, fill())
                if (d == NoteDuration.SIXTEENTH) c.drawCircle(x - 0.38f * s, y + 0.15f * s, r, fill())
            }
            else -> drawRest(d.base, ctr, s, c)
        }
    }

    private fun drawTreble(x: Float, t: Float, s: Float, c: Canvas) {
        val g = t + 3 * s
        val spine = Path()
        spine.moveTo(x + 0.3f * s, t - 1.6f * s)
        spine.cubicTo(x + 1.3f * s, t + 0.4f * s, x - 1.1f * s, t + 2.6f * s, x, g + 1.6f * s)
        c.drawPath(spine, stroke(1.4f))
        c.drawOval(RectF(x - 0.75f * s, g - 0.75f * s, x + 0.75f * s, g + 0.75f * s), stroke(1.4f))
        c.drawCircle(x, g + 1.6f * s, 0.3f * s, fill())
    }

    private fun drawBass(x: Float, t: Float, s: Float, c: Canvas) {
        val f = t + s
        c.drawCircle(x - 0.8f * s, f, 0.35f * s, fill())
        val swash = Path()
        swash.moveTo(x - 0.8f * s, f - 0.1f * s)
        swash.cubicTo(x - 0.6f * s, t - 1.0f * s, x + 1.2f * s, t - 0.6f * s, x + 0.9f * s, f + 0.2f * s)
        swash.cubicTo(x + 0.7f * s, f + 1.4f * s, x + 0.4f * s, t + 3.0f * s, x - 0.2f * s, t + 3.6f * s)
        c.drawPath(swash, stroke(1.4f))
        for (dy in floatArrayOf(-0.4f * s, 0.4f * s)) c.drawCircle(x + 1.6f * s, f + dy, 0.22f * s, fill())
    }
}

/** Vector PDF of a score (spec 7): one PDF page per laid page via [PdfDocument] (its canvas records vector drawing ops, not rasters). */
object ScorePdf {
    /** A4 in PDF points. Empty result only on a platform failure. */
    fun makePdf(score: ScoreDocument, title: String, instrument: com.levi.pocketdj.studio.model.InstrumentKey): ByteArray {
        val metrics = ScoreLayout.Metrics.A4
        val pages = ScoreLayout.paginate(score, title, instrument, metrics)
        val doc = PdfDocument()
        return try {
            for ((i, p) in pages.withIndex()) {
                val info = PdfDocument.PageInfo.Builder(Math.round(p.width), Math.round(p.height), i + 1).create()
                val page = doc.startPage(info)
                ScoreRenderer.draw(p, page.canvas)
                doc.finishPage(page)
            }
            val out = ByteArrayOutputStream()
            doc.writeTo(out)
            out.toByteArray()
        } catch (e: Exception) {
            ByteArray(0)
        } finally { doc.close() }
    }
}
