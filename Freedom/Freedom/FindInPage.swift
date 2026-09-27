import Foundation

/// Safari-style find in page: while the address bar is being edited the
/// page is searched for the typed text and an "On This Page" row shows
/// the count; tapping it hands the term to the system find navigator
/// (highlights, next / previous, Done). Pure helpers here; the tab owns
/// the web view calls.
enum FindInPage {
    /// Minimum typed length before the page is searched.
    static let minimumQueryLength = 1
    /// Typing settles for this long before the page is searched again.
    static let debounceMilliseconds: UInt64 = 150

    /// JavaScript that counts case-insensitive, non-overlapping
    /// occurrences of `query` in the document's rendered text
    /// (`innerText`: hidden elements and script content excluded).
    static func countScript(for query: String) -> String {
        let encoded = (try? JSONSerialization.data(withJSONObject: [query]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return """
        (() => {
          const q = \(encoded)[0].toLowerCase();
          if (!q) return 0;
          const body = document.body;
          if (!body) return 0;
          const text = (body.innerText || '').toLowerCase();
          let n = 0, i = 0;
          while ((i = text.indexOf(q, i)) !== -1) { n += 1; i += q.length; }
          return n;
        })()
        """
    }

    static func label(count: Int, query: String) -> String {
        "\(count) \(count == 1 ? "match" : "matches") for “\(query)”"
    }
}
