import Foundation
import ZIPFoundation

enum EPUBReader {
    static func read(_ url: URL) throws -> String {
        guard let archive = Archive(url: url, accessMode: .read) else {
            throw NSError(domain:"LeafVoice",code:10,userInfo:[NSLocalizedDescriptionKey:"Cannot open EPUB archive"])
        }
        var pages: [(String,String)] = []
        for entry in archive {
            let name = entry.path.lowercased()
            guard name.hasSuffix(".xhtml") || name.hasSuffix(".html") || name.hasSuffix(".htm") else { continue }
            var bytes = Data()
            _ = try archive.extract(entry, consumer: { chunk in bytes.append(chunk) })
            guard let html = String(data:bytes,encoding:.utf8) else { continue }
            let cleaned = html
                .replacingOccurrences(of:"(?is)<(script|style|svg|nav)\\b[^>]*>.*?</\\1>",with:" ",options:.regularExpression)
                .replacingOccurrences(of:"(?i)</(p|h[1-6]|div|li|section|blockquote)>",with:"\n",options:.regularExpression)
                .replacingOccurrences(of:"(?s)<[^>]+>",with:" ",options:.regularExpression)
                .replacingOccurrences(of:"&nbsp;",with:" ")
                .replacingOccurrences(of:"&amp;",with:"&")
                .replacingOccurrences(of:"&lt;",with:"<")
                .replacingOccurrences(of:"&gt;",with:">")
                .replacingOccurrences(of:"&quot;",with:"\"")
                .replacingOccurrences(of:"&#39;",with:"'")
                .replacingOccurrences(of:"[ \\t]+",with:" ",options:.regularExpression)
            pages.append((entry.path,cleaned))
        }
        pages.sort { $0.0.localizedStandardCompare($1.0) == .orderedAscending }
        let result = pages.map(\.1).joined(separator:"\n\n")
        guard !result.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
            throw NSError(domain:"LeafVoice",code:11,userInfo:[NSLocalizedDescriptionKey:"This EPUB has no readable chapters."])
        }
        return result
    }
}
