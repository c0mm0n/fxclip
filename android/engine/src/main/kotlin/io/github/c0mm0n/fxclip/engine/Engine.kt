package io.github.c0mm0n.fxclip.engine

import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.CodingErrorAction

data class CleanResult(val text: String, val removed: Int)

/** Tracker removal and preview rewriting, driven by a rule set. Pure functions, no clipboard. Port of the C# engine. */
class Engine(val rules: Rules) {

    /** Cleans every URL in text. `removed` counts the trackers taken out. */
    fun clean(text: String): CleanResult {
        var removed = 0
        val out = mapUrls(text) { url ->
            val (cleaned, n) = cleanUrl(url)
            removed += n
            cleaned
        }
        return CleanResult(out, removed)
    }

    /** Works on the raw string: kept parameters stay byte-for-byte (no re-encoding of %2B, ==…). */
    private fun cleanUrl(url: String): Pair<String, Int> {
        val host = host(url) ?: return url to 0
        if (rules.neverClean.orEmpty().any { it.covers(host) }) return url to 0
        val hash = url.indexOf('#')
        val fragment = if (hash < 0) "" else url.substring(hash)
        val beforeHash = if (hash < 0) url else url.substring(0, hash)
        val q = beforeHash.indexOf('?')
        var base = if (q < 0) beforeHash else beforeHash.substring(0, q)
        val segments = if (q < 0) emptyList() else beforeHash.substring(q + 1).split('&')
        val sites = rules.trackers.sites.filter { s -> s.hosts.any { host == it || host.endsWith(".$it") } }
        val changedPath = sites.any { it.stripRefPath == true } && refPath.containsMatchIn(base)
        if (changedPath) base = refPath.replace(base, "")
        val local = sites.flatMap { it.params }.toSet()
        val global = rules.trackers.everywhere
        val kept = segments.filter { segment ->
            val equal = segment.indexOf('=')
            val raw = if (equal < 0) segment else segment.substring(0, equal)
            val name = percentDecode(raw) ?: raw
            name !in global.params && name !in local && global.prefixes.none { name.startsWith(it, ignoreCase = true) }
        }
        if (kept.size == segments.size && !changedPath) return url to 0
        val removed = segments.size - kept.size + if (changedPath) 1 else 0
        return base + (if (kept.isEmpty()) "" else "?" + kept.joinToString("&")) + fragment to removed
    }

    /** The rewrites that apply in the front app: bundle ID, app_id, exe name or Android package. */
    fun previewsFor(identifier: String): List<PreviewRule> {
        val ids = rules.apps.filter { it.matches(identifier) }.map { it.id }.toSet()
        return rules.previews.filter { p -> p.apps.any { it in ids } }
    }

    /** Rewrites every URL in text to its embed mirror for that app; text is assumed already cleaned. */
    fun preview(text: String, identifier: String): String = applyPreviews(text, previewsFor(identifier))

    /** Every enabled preview rewrite, whatever the app ("Preview link" in the text menu). */
    fun previewAll(text: String): String = applyPreviews(text, rules.previews)

    private fun applyPreviews(text: String, active: List<PreviewRule>): String {
        if (active.isEmpty()) return text
        return mapUrls(text) { url ->
            // Anchored on the URL start; only an exact listed host followed by "/" matches.
            val schemeLength = if (url.startsWith("https://", ignoreCase = true)) 8 else 7
            val slash = url.indexOf('/', schemeLength)
            if (slash < 0) return@mapUrls url
            val host = url.substring(schemeLength, slash).lowercase()
            val rule = active.firstOrNull { host in it.from }
            if (rule == null) url else "https://" + rule.to + url.substring(slash)
        }
    }

    companion object {
        // \s is ASCII-only on the JVM and Unicode-aware in NSRegularExpression and .NET, and Android's
        // regex rejects the (?U) flag, so the Unicode spaces are listed.
        private val urls = Regex(
            "https?://[^\\s\\u0085\\u00A0\\u1680\\u2000-\\u200A\\u2028\\u2029\\u202F\\u205F\\u3000<>\"'`]+",
            RegexOption.IGNORE_CASE,
        )
        private val refPath = Regex("/ref=[^/]*$")

        /** True when the whole (trimmed) text is a single URL. */
        fun isBareUrl(text: String): Boolean {
            val trimmed = text.trim()
            val m = urls.find(trimmed) ?: return false
            return m.range.first == 0 && m.range.last == trimmed.length - 1
        }

        /** True when the text holds at least one link. */
        fun containsUrl(text: String): Boolean = urls.containsMatchIn(text)

        /** Applies map to each URL, leaving prose punctuation around it untouched. */
        private fun mapUrls(text: String, map: (String) -> String): String {
            var output = text
            for (match in urls.findAll(text).toList().asReversed()) {
                val start = match.range.first
                var end = match.range.last + 1
                var parens = 0
                var brackets = 0
                for (ch in match.value) {
                    when (ch) {
                        '(' -> parens++
                        ')' -> parens--
                        '[' -> brackets++
                        ']' -> brackets--
                    }
                }
                while (end > start) {
                    val last = output[end - 1]
                    if (last == ')' && parens < 0) parens++
                    else if (last == ']' && brackets < 0) brackets++
                    else if (last !in ".,;:!?") break
                    end--
                }
                output = output.substring(0, start) + map(output.substring(start, end)) + output.substring(end)
            }
            return output
        }

        /** Extracts just the host. Never round-trips through java.net.URI: it changes raw URLs. */
        fun host(url: String): String? {
            val scheme = url.indexOf("://")
            if (scheme < 0) return null
            val end = url.indexOfAny(charArrayOf('/', '?', '#'), scheme + 3)
            var authority = if (end < 0) url.substring(scheme + 3) else url.substring(scheme + 3, end)
            val at = authority.lastIndexOf('@')
            if (at >= 0) authority = authority.substring(at + 1)
            if (authority.startsWith('[')) {
                val close = authority.indexOf(']')
                return if (close < 0) null else authority.substring(0, close + 1).lowercase()
            }
            val colon = authority.lastIndexOf(':')
            if (colon >= 0) {
                if (authority.substring(colon + 1).any { it !in '0'..'9' }) return null
                authority = authority.substring(0, colon)
            }
            val decoded = percentDecode(authority)
            return if (decoded.isNullOrEmpty() || decoded.any { it.isWhitespace() || it in "\\[]" }) null else decoded.lowercase()
        }

        /** Strict UTF-8 percent decoding; null when malformed (like Swift's removingPercentEncoding). */
        private fun percentDecode(raw: String): String? {
            val output = StringBuilder()
            var i = 0
            while (i < raw.length) {
                if (raw[i] != '%') {
                    output.append(raw[i]); i++; continue
                }
                val bytes = ArrayList<Byte>()
                while (i < raw.length && raw[i] == '%') {
                    if (i + 2 >= raw.length) return null
                    val hi = Character.digit(raw[i + 1], 16)
                    val lo = Character.digit(raw[i + 2], 16)
                    if (hi < 0 || lo < 0) return null
                    bytes.add(((hi shl 4) or lo).toByte())
                    i += 3
                }
                val decoder = Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                try {
                    output.append(decoder.decode(ByteBuffer.wrap(bytes.toByteArray())))
                } catch (_: CharacterCodingException) {
                    return null
                }
            }
            return output.toString()
        }
    }
}
