#if canImport(JavaScriptCore)
import Foundation
import JavaScriptCore

/// Solves YouTube's `n` and signature challenges with yt-dlp's EJS solver (github.com/yt-dlp/ejs, v0.8.0)
/// running in JavaScriptCore — the same scripts yt-dlp runs in deno/node/quickjs.
public final class JSChallengeSolver: ChallengeSolving, @unchecked Sendable {
    private let cacheDir: URL
    private let lock = NSLock()

    public init(cacheDir: URL = FileManager.default.temporaryDirectory) { self.cacheDir = cacheDir }

    static let scripts: (lib: String, core: String)? = {
        guard let lib = Bundle.module.url(forResource: "yt.solver.lib.min", withExtension: "js"),
              let core = Bundle.module.url(forResource: "yt.solver.core.min", withExtension: "js"),
              let l = try? String(contentsOf: lib, encoding: .utf8),
              let c = try? String(contentsOf: core, encoding: .utf8) else { return nil }
        return (l, c)
    }()

    public func solve(playerID: String, player: String, n: [String], sig: [String]) throws -> (n: [String: String], sig: [String: String]) {
        lock.lock(); defer { lock.unlock() }
        guard let scripts = Self.scripts else { throw ExtractionError.network("Challenge solver is missing from the app.") }
        // The preprocessed player skips the expensive JS parse next time (it uses lots of memory).
        let cache = cacheDir.appendingPathComponent("preprocessed-\(playerID).js")
        let pre = try? String(contentsOf: cache, encoding: .utf8)

        var requests: [[String: Any]] = []
        if !n.isEmpty { requests.append(["type": "n", "challenges": n]) }
        if !sig.isEmpty { requests.append(["type": "sig", "challenges": sig]) }
        let input: [String: Any] = pre != nil
            ? ["type": "preprocessed", "preprocessed_player": pre!, "requests": requests]
            : ["type": "player", "player": player, "requests": requests, "output_preprocessed": true]

        guard let ctx = JSContext() else { throw ExtractionError.network("JavaScript engine unavailable.") }
        var jsError: String?
        ctx.exceptionHandler = { _, e in jsError = e?.toString() }
        ctx.evaluateScript(scripts.lib)
        ctx.evaluateScript("Object.assign(globalThis, lib);")
        ctx.evaluateScript(scripts.core)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
        ctx.setObject(json, forKeyedSubscript: "__input" as NSString)
        let out = ctx.evaluateScript("JSON.stringify(jsc(JSON.parse(__input)))")?.toString() ?? ""
        if let jsError { throw ExtractionError.network("Couldn't solve YouTube's player challenge: \(jsError)") }

        guard let obj = try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any], obj["type"] as? String == "result",
              let responses = obj["responses"] as? [[String: Any]] else {
            throw ExtractionError.network("Couldn't solve YouTube's player challenge: \((try? JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])?["error"] ?? out.prefix(200))")
        }
        if pre == nil, let p = obj["preprocessed_player"] as? String { try? p.write(to: cache, atomically: true, encoding: .utf8) }

        var result: (n: [String: String], sig: [String: String]) = ([:], [:])
        for (req, resp) in zip(requests, responses) {
            guard resp["type"] as? String == "result", let data = resp["data"] as? [String: String] else {
                throw ExtractionError.network("Couldn't solve YouTube's \(req["type"] ?? "") challenge: \(resp["error"] ?? "unknown error")")
            }
            if req["type"] as? String == "n" { result.n = data } else { result.sig = data }
        }
        return result
    }
}
#endif
