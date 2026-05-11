import Foundation

/// Render the HTML body that scheme handlers serve when ENS resolution
/// fails or the resolved codec doesn't match the request scheme. Mirrors
/// desktop Freedom's "cross-transport mismatches return 404 with an
/// explanatory body" behavior — silently switching schemes when a user
/// typed `bzz://name.eth/` for an IPFS-coded name is a worse experience
/// than telling them what happened.
enum SchemeHandlerErrorPage {
    enum Kind {
        case codecMismatch(requestedScheme: String, resolvedScheme: String, name: String)
        case resolutionFailed(name: String, message: String)
    }

    static func render(_ kind: Kind) -> String {
        switch kind {
        case let .codecMismatch(requestedScheme, resolvedScheme, name):
            let suggestion = "\(resolvedScheme)://\(escape(name))/"
            return page(
                title: "Wrong scheme for \(escape(name))",
                heading: "Wrong scheme",
                body: """
                <p><code>\(escape(name))</code> is published on <strong>\(escape(resolvedScheme))</strong>, \
                but you requested it as <strong>\(escape(requestedScheme))</strong>.</p>
                <p>Try <a href="\(suggestion)"><code>\(suggestion)</code></a>.</p>
                """
            )
        case let .resolutionFailed(name, message):
            return page(
                title: "Couldn't resolve \(escape(name))",
                heading: "Resolution failed",
                body: """
                <p>Couldn't resolve <code>\(escape(name))</code>.</p>
                <p class="detail">\(escape(message))</p>
                """
            )
        }
    }

    private static func page(title: String, heading: String, body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(title)</title>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body{margin:0;padding:0;background:#fafafa;color:#1c1c1e;font:-apple-system-body;font-family:-apple-system,system-ui,sans-serif}
          main{max-width:36rem;margin:4rem auto;padding:0 1.25rem}
          h1{font-size:1.5rem;margin:0 0 1rem}
          p{line-height:1.5}
          code{font-family:ui-monospace,SFMono-Regular,Menlo,monospace;font-size:0.95em;background:#eef;padding:1px 4px;border-radius:3px}
          a{color:#0a84ff;text-decoration:none}
          a:hover{text-decoration:underline}
          .detail{color:#6c6c70;font-size:0.95em}
          @media (prefers-color-scheme:dark){
            html,body{background:#000;color:#f2f2f7}
            code{background:#1c1c1e}
            .detail{color:#9c9ca0}
          }
        </style></head>
        <body><main><h1>\(heading)</h1>\(body)</main></body></html>
        """
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out.append("&amp;")
            case "<": out.append("&lt;")
            case ">": out.append("&gt;")
            case "\"": out.append("&quot;")
            case "'": out.append("&#39;")
            default: out.append(ch)
            }
        }
        return out
    }
}
