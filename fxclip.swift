// fxclip — clipboard link hygiene.
// - Everywhere: strips tracking / affiliate parameters from copied links (utm_*,
//   fbclid, YouTube si, Instagram igsh, Amazon tag…). Permanent.
// - While Telegram is frontmost: rewrites x.com / twitter.com to fxtwitter.com and
//   instagram.com to zzinstagram.com so Telegram shows a proper preview; the clean
//   original link is put back on leaving.
// Polls the pasteboard change counter (cheap, no process spawn) and only touches
// plain-text clipboards.
import AppKit

// MARK: tracking removal

// Dropped on every host.
let globalParams: Set<String> = [
    "fbclid", "gclid", "gclsrc", "dclid", "gbraid", "wbraid", "msclkid", "yclid",
    "twclid", "ttclid", "li_fat_id", "igshid", "igsh", "mc_cid", "mc_eid",
    "_hsenc", "_hsmi", "mkt_tok", "oly_anon_id", "oly_enc_id", "vero_id", "srsltid",
]
let globalPrefixes = ["utm_", "aff_", "pk_", "mtm_"]

let amazonHosts = ["amazon.com", "amazon.fr", "amazon.de", "amazon.co.uk", "amazon.it", "amazon.es", "amzn.to", "amzn.eu"]

// Dropped only on these hosts (the same name is meaningful elsewhere, e.g. ?ref= on GitHub).
let hostParams: [(hosts: [String], params: Set<String>)] = [
    (["x.com", "twitter.com"], ["s", "t", "ref_src", "ref_url"]),
    (["youtube.com", "youtu.be"], ["si", "feature", "pp", "ab_channel"]),
    (["instagram.com"], ["igsh", "igshid", "img_index_ref", "exln"]),
    (["tiktok.com"], ["_t", "_r", "is_from_webapp", "sender_device", "is_copy_url", "refer"]),
    (["spotify.com"], ["si", "context", "nd", "dlsi"]),
    (amazonHosts,
     ["tag", "ref", "ref_", "linkCode", "linkId", "ascsubtag", "creative", "creativeASIN",
      "camp", "content-id", "pd_rd_w", "pd_rd_r", "pd_rd_wg", "pd_rd_i", "pf_rd_p", "pf_rd_r",
      "dib", "dib_tag", "_encoding"]),
    (["aliexpress.com"], ["sk", "spm", "scm", "pvid", "algo_pvid", "algo_exp_id", "terminal_id", "afSmartRedirect", "gatewayAdapt"]),
    (["facebook.com"], ["mibextid", "rdid", "share_url", "sfnsn"]),
    (["linkedin.com"], ["trk", "trackingId", "lipi", "rcm"]),
    (["reddit.com"], ["share_id", "rdt", "ref", "ref_source", "context"]),
]

func matches(_ host: String, _ domain: String) -> Bool {
    host == domain || host.hasSuffix("." + domain)
}

let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`]+"#, options: [.caseInsensitive])

// Applies f to each URL in text, leaving prose punctuation around it untouched:
// "see (https://x.com/a)." → f("https://x.com/a").
func mapURLs(_ text: String, _ f: (String) -> String) -> String {
    var out = text
    // Replace from the end so earlier ranges stay valid.
    for m in urlPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
        guard var r = Range(m.range, in: out) else { continue }
        // Bracket balance counted once, updated as we trim.
        var parens = 0, brackets = 0
        for ch in out[r] {
            switch ch {
            case "(": parens += 1
            case ")": parens -= 1
            case "[": brackets += 1
            case "]": brackets -= 1
            default: break
            }
        }
        while let last = out[r].last {
            if last == ")" && parens < 0 { parens += 1 }
            else if last == "]" && brackets < 0 { brackets += 1 }
            else if !".,;:!?".contains(last) { break }
            r = r.lowerBound..<out.index(before: r.upperBound)
        }
        out.replaceSubrange(r, with: f(String(out[r])))
    }
    return out
}

// Works on the raw string: kept parameters stay byte-for-byte (no re-encoding of %2B, ==…).
func cleanURL(_ s: String) -> String {
    guard let host = URLComponents(string: s)?.host?.lowercased() else { return s }
    let hash = s.firstIndex(of: "#")
    let fragment = hash.map { String(s[$0...]) } ?? ""
    let beforeHash = hash.map { String(s[..<$0]) } ?? s
    let q = beforeHash.firstIndex(of: "?")
    var base = q.map { String(beforeHash[..<$0]) } ?? beforeHash
    let segments = q.map { beforeHash[beforeHash.index(after: $0)...].split(separator: "&", omittingEmptySubsequences: false) } ?? []

    // Amazon puts its referral in the path: /dp/B0XXXX/ref=sr_1_1
    if amazonHosts.contains(where: { matches(host, $0) }),
       let r = base.range(of: #"/ref=[^/]*$"#, options: .regularExpression) {
        base.removeSubrange(r)
    }
    let local = hostParams.filter { $0.hosts.contains { matches(host, $0) } }.flatMap(\.params)
    let kept = segments.filter { seg in
        let raw = String(seg[..<(seg.firstIndex(of: "=") ?? seg.endIndex)])
        let n = raw.removingPercentEncoding ?? raw
        return !globalParams.contains(n) && !local.contains(n)
            && !globalPrefixes.contains { n.lowercased().hasPrefix($0) }
    }
    let baseUnchanged = base.count == (q.map { beforeHash.distance(from: beforeHash.startIndex, to: $0) } ?? beforeHash.count)
    guard kept.count != segments.count || !baseUnchanged else { return s }
    return base + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&")) + fragment
}

func clean(_ text: String) -> String { mapURLs(text, cleanURL) }

// MARK: embed mirrors

// Embed-friendly mirrors, used only while pasting into Telegram. Anchored on the
// URL start: a link nested in another link's query is left alone.
let embedMirrors: [(NSRegularExpression, String)] = [
    (#"^https?://(?:www\.|mobile\.)?(?:x|twitter)\.com/"#, "https://fxtwitter.com/"),
    (#"^https?://(?:www\.)?instagram\.com/"#, "https://zzinstagram.com/"),
].map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }

func embedURL(_ u: String) -> String {
    for (re, to) in embedMirrors {
        if let m = re.firstMatch(in: u, range: NSRange(u.startIndex..., in: u)), let r = Range(m.range, in: u) {
            return to + u[r.upperBound...]
        }
    }
    return u
}

func embedify(_ text: String) -> String { mapURLs(text, embedURL) }

if CommandLine.arguments.count > 1 {  // test mode: fxclip "<text>" → clean, then telegram version
    let c = clean(CommandLine.arguments[1])
    print(c)
    print(embedify(c))
    exit(0)
}

// MARK: clipboard loop

let pb = NSPasteboard.general
var lastCount = pb.changeCount
let telegramIDs: Set<String> = ["ru.keepcoder.Telegram", "org.telegram.desktop", "com.tdesktop.Telegram"]
var original: String?  // clean clipboard before the embed rewrite, restored outside Telegram
var ourCount = -1      // changeCount right after our last write

func telegramIsFront() -> Bool {
    telegramIDs.contains(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "")
}

func write(_ s: String) {
    // clearContents() returns our own generation; reading changeCount afterwards
    // could pick up a copy made in between.
    ourCount = pb.clearContents()
    pb.setString(s, forType: .string)
}

let richTypes: [NSPasteboard.PasteboardType] = [.html, .rtf, .rtfd]

func processClipboard(front: Bool) {
    let count = pb.changeCount
    // A new copy supersedes whatever we were holding for restore.
    original = nil
    // Leave images and files alone. Rich text (copied from a page) is only rewritten
    // when it is a bare link — flattening anything longer would lose its formatting.
    guard let types = pb.types, types.contains(.string),
          !types.contains(.fileURL), !pb.canReadObject(forClasses: [NSImage.self]),
          let text = pb.string(forType: .string) else { return }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let bareURL = urlPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))?
        .range == NSRange(trimmed.startIndex..., in: trimmed)
    if types.contains(where: richTypes.contains) && !bareURL { return }
    let cleaned = clean(text)
    let out = front ? embedify(cleaned) : cleaned
    // Someone copied again while we worked: drop ours, the next tick handles theirs.
    guard out != text, pb.changeCount == count else { return }
    write(out)
    if out != cleaned { original = cleaned }
}

func tick() {
    let front = telegramIsFront()
    if !front, let text = original {
        // Only if nobody copied anything since our rewrite.
        if pb.changeCount == ourCount { write(text) }
        original = nil
    }
    let count = pb.changeCount
    guard count != lastCount else { return }
    if count != ourCount { processClipboard(front: front) }
    // Our own write is already processed; a copy that landed meanwhile is not.
    lastCount = pb.changeCount == ourCount ? ourCount : count
}

// Act at once on app switch; poll for copies.
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
) { _ in
    // Re-process the current clipboard on entering Telegram (it was already cleaned).
    if telegramIsFront() && original == nil { processClipboard(front: true) }
    tick()
}
Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in tick() }
RunLoop.main.run()
