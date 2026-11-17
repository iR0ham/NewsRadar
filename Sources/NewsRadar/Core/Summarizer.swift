import Foundation

/// Which service writes the summaries.
///
/// Both are optional. When neither answers, the app falls back to its own
/// offline digest, so it always works with no service configured at all.
enum SummaryEngine: String, Codable, CaseIterable, Hashable {
    /// A local Ollama server (`/api/tags`, `/api/generate`).
    case ollama
    /// 9router, a local gateway exposing an OpenAI-compatible API
    /// (`/v1/models`, `/v1/chat/completions`) in front of many providers.
    case router9 = "9router"

    var title: String {
        switch self {
        case .ollama: return "Ollama"
        case .router9: return "9router"
        }
    }

    var detail: String {
        switch self {
        case .ollama:
            return "A model running on this Mac through Ollama."
        case .router9:
            return "9router's local OpenAI-compatible gateway, which forwards to a provider."
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://127.0.0.1:11434"
        case .router9: return "http://127.0.0.1:20128/v1"
        }
    }

    /// Ollama needs no credentials. 9router requires a key for every request.
    var needsAPIKey: Bool { self == .router9 }
}

/// Configuration for the summary service. One struct covers both engines so the
/// rest of the app never branches on which service is in use.
struct OllamaConfig: Codable, Hashable {
    /// Which service to talk to.
    var engine: SummaryEngine = .ollama
    var enabled: Bool = false
    var baseURL: String = SummaryEngine.ollama.defaultBaseURL
    var model: String = ""
    /// Bearer token. Only 9router uses it; stored on this Mac in `state.json`.
    var apiKey: String = ""
    var timeout: Double = 60
    /// Discovered model names, filled by the client's model listing.
    var knownModels: [String] = []
    var lastError: String?
    var lastChecked: Date?

    var isConfigured: Bool {
        enabled && !model.isEmpty && (!engine.needsAPIKey || !apiKey.isEmpty)
    }

    /// The engine tag recorded on every rendered item, so a card can state which
    /// service produced its summary and never claims more than happened.
    var engineTag: String { "\(engine.rawValue):\(model)" }
}

/// Client for whichever summary service is configured.
///
/// * Ollama speaks its own two endpoints.
/// * 9router speaks the OpenAI chat-completions shape, with a bearer key.
///
/// Both are wrapped so the summariser only ever sees "generate some text from a
/// prompt" and "list the models I can use".
enum ModelClient {

    // MARK: - URLs

    /// Appends `path` to `base`, tolerating a trailing slash and a base that
    /// already carries the `/v1` prefix (9router users paste either form).
    static func url(_ base: String, _ path: String) -> URL? {
        var root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.hasSuffix("/") { root.removeLast() }
        guard !root.isEmpty else { return nil }
        let needsV1 = path.hasPrefix("v1/") && !root.hasSuffix("/v1")
        let full = root + (needsV1 ? "/" + path : "/" + (path.hasPrefix("v1/") ? String(path.dropFirst(3)) : path))
        return URL(string: full)
    }

    // MARK: - Model discovery

    static func availableModels(config: OllamaConfig, timeout: Double = 6) -> [String] {
        switch config.engine {
        case .ollama:
            guard let u = url(config.baseURL, "api/tags"),
                  let r = try? HTTP.get(u, timeout: timeout, retries: 0),
                  let t = try? JSONDecoder().decode(OllamaTags.self, from: r.data)
            else { return [] }
            return (t.models ?? []).map { $0.model ?? $0.name }
        case .router9:
            guard let u = url(config.baseURL, "v1/models"),
                  let r = try? HTTP.get(u, timeout: timeout, retries: 0,
                                        bearer: config.apiKey),
                  let t = try? JSONDecoder().decode(OpenAIModels.self, from: r.data)
            else { return [] }
            return (t.data ?? []).map { $0.id }.sorted()
        }
    }

    static func isReachable(config: OllamaConfig, timeout: Double = 4) -> Bool {
        !availableModels(config: config, timeout: timeout).isEmpty
    }

    // MARK: - Generation

    /// One-shot generation. Returns nil when the service is unavailable, which
    /// callers treat as "use the offline digest".
    static func generate(config: OllamaConfig, prompt: String,
                         maxTokens: Int = 700) -> String? {
        switch config.engine {
        case .ollama:
            guard let u = url(config.baseURL, "api/generate") else { return nil }
            let payload: [String: Any] = [
                "model": config.model,
                "prompt": prompt,
                "stream": false,
                "options": ["temperature": 0.2, "num_predict": maxTokens]
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.timeoutInterval = config.timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = data
            guard let body = post(req),
                  let decoded = try? JSONDecoder().decode(OllamaGenerate.self, from: body)
            else { return nil }
            if let err = decoded.error, !err.isEmpty { return nil }
            return decoded.response

        case .router9:
            guard let u = url(config.baseURL, "v1/chat/completions") else { return nil }
            let payload: [String: Any] = [
                "model": config.model,
                "messages": [["role": "user", "content": prompt]],
                "temperature": 0.2,
                "max_tokens": maxTokens,
                "stream": false
            ]
            guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
            var req = URLRequest(url: u)
            req.httpMethod = "POST"
            req.timeoutInterval = config.timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if !config.apiKey.isEmpty {
                req.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            }
            req.httpBody = data
            guard let body = post(req),
                  let decoded = try? JSONDecoder().decode(OpenAIChat.self, from: body)
            else { return nil }
            if let err = decoded.error?.message, !err.isEmpty { return nil }
            return decoded.choices?.first?.message?.content
        }
    }

    /// Blocking POST with a hard deadline; used only from the background
    /// summarisation queue.
    private static func post(_ req: URLRequest) -> Data? {
        let sem = DispatchSemaphore(value: 0)
        var body: Data?
        let task = URLSession.shared.dataTask(with: req) { data, _, _ in
            body = data
            sem.signal()
        }
        task.resume()
        let deadline = Date().addingTimeInterval(req.timeoutInterval + 5)
        while sem.wait(timeout: .now() + 0.2) == .timedOut {
            if Date() > deadline {
                task.cancel()
                return nil
            }
        }
        return body
    }

    // MARK: - Wire shapes

    struct OllamaTags: Decodable {
        struct Model: Decodable { var name: String; var model: String? }
        var models: [Model]?
    }

    struct OllamaGenerate: Decodable {
        var response: String?
        var done: Bool?
        var error: String?
    }

    struct OpenAIModels: Decodable {
        struct Entry: Decodable { var id: String }
        var data: [Entry]?
    }

    struct OpenAIChat: Decodable {
        struct Choice: Decodable { var message: Message? }
        struct Message: Decodable { var content: String? }
        struct APIError: Decodable { var message: String? }
        var choices: [Choice]?
        var error: APIError?
    }
}

/// How an engine tag (`source`, `digest`, `local`, `ollama:<model>`,
/// `9router:<model>`) is described in the UI. Centralised because the badge is
/// shown in three places and each one used to test only for "ollama", which
/// labelled every 9router summary as an offline digest.
enum EngineLabel {
    struct Info {
        var title: String
        var symbol: String
        var isModel: Bool
    }

    static func describe(_ tag: String) -> Info {
        if let colon = tag.firstIndex(of: ":") {
            let engine = String(tag[tag.startIndex..<colon])
            let model = String(tag[tag.index(after: colon)...])
            switch engine {
            case "ollama":
                return Info(title: "Local model: \(model)", symbol: "sparkles", isModel: true)
            case SummaryEngine.router9.rawValue:
                return Info(title: "9router: \(model)", symbol: "arrow.triangle.branch", isModel: true)
            default:
                return Info(title: tag, symbol: "cpu", isModel: false)
            }
        }
        switch tag {
        case "local": return Info(title: "Offline digest", symbol: "cpu", isModel: false)
        case "source": return Info(title: "From the source", symbol: "doc.text", isModel: false)
        case "digest": return Info(title: "Offline digest", symbol: "cpu", isModel: false)
        default: return Info(title: tag.capitalized, symbol: "cpu", isModel: false)
        }
    }
}

/// Produces the headline, short summary and key points for one item.
///
/// Three engines, recorded on the item so the UI never claims more than happened:
///  * `source` — the feed's own description, cleaned and trimmed.
///  * `digest` — a summary composed from measured data when the feed had none.
///  * `ollama:<model>` — a local model rewrites the item.
enum Summarizer {

    static func render(_ item: RadarItem, ollama: OllamaConfig?) -> RadarItem {
        var out = item
        if let config = ollama, config.isConfigured,
           let text = ollamaSummary(item, config: config) {
            out.headline = text.headline.isEmpty ? cleanedHeadline(item) : text.headline
            out.summary = text.summary
            out.keyPoints = text.points.isEmpty ? Classifier.facts(for: out) : text.points
            out.summaryEngine = config.engineTag
            return out
        }
        return offlineRender(item)
    }

    /// The deterministic renderer: no network, no model, no invented text.
    static func offlineRender(_ item: RadarItem) -> RadarItem {
        var out = item
        out.headline = cleanedHeadline(item)
        if let text = cleanedSummary(item) {
            out.summary = text
            out.summaryEngine = "source"
        } else {
            out.summary = digest(for: item)
            out.summaryEngine = "digest"
        }
        out.keyPoints = Classifier.facts(for: out)
        return out
    }

    struct Rendered {
        var headline: String
        var summary: String
        var points: [String]
    }

    // MARK: - Offline text

    /// The source headline, with stray whitespace and trailing separators gone.
    /// Headlines are never rewritten: the feed's wording is the accurate one.
    static func cleanedHeadline(_ item: RadarItem) -> String {
        var t = TextFormat.clean(item.title)
        t = t.replacingOccurrences(of: "(?i)\\s*[-–—|]\\s*(techcrunch|the verge|tldr|product hunt|google)\\s*$",
                                   with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|·"))
        return t.isEmpty ? item.title : t
    }

    /// The feed's own description, used as the summary.
    ///
    /// Rejected when it is too thin to be a summary: some feeds publish only the
    /// headline (TLDR) or a tagline followed by navigation words (Product Hunt).
    /// Those items are better served by the digest, which restates the title as
    /// a sentence and adds the measured facts.
    /// The feed's body text with trailing navigation links removed. Feeds append
    /// these ("… Discussion | Link"), sometimes several in a row, so the strip runs
    /// until the text stops changing.
    static func cleanedSourceText(_ raw: String) -> String {
        var text = TextFormat.clean(raw)
        let navPattern = "(?i)\\s*[-–—|·]?\\s*(discussion|comments?|link|read more|continue reading|"
            + "permalink|source|website)\\s*$"
        for _ in 0..<4 {
            let stripped = text.replacingOccurrences(of: navPattern, with: "",
                                                     options: .regularExpression)
            if stripped == text { break }
            text = stripped
        }
        return text.trimmingCharacters(in: CharacterSet(charactersIn: " -–—|·,"))
    }

    /// True for bodies that are a placeholder rather than prose ("TBD", "Coming
    /// soon", "…"). Treating those as a summary would put nothing useful on a card.
    static func isPlaceholderText(_ s: String) -> Bool {
        let t = TextFormat.clean(s).lowercased()
        guard t.count < 24 else { return false }
        return Signals.placeholderBodies.contains(t)
            || t.trimmingCharacters(in: CharacterSet(charactersIn: ".… ")).isEmpty
    }

    static func cleanedSummary(_ item: RadarItem) -> String? {
        let text = cleanedSourceText(item.rawSummary)
        guard !isPlaceholderText(text) else { return nil }
        // Below this length the feed gave a tagline, not a summary; the digest
        // carries more information than the tagline did.
        guard text.count >= 70 else { return nil }
        // A description identical to the headline is not a summary.
        let norm = { (s: String) in TextFormat.clean(s).lowercased() }
        let plainTitle = norm(item.title).replacingOccurrences(of: "[^a-z0-9 ]", with: "",
                                                              options: .regularExpression)
        let plainText = norm(text).replacingOccurrences(of: "[^a-z0-9 ]", with: "",
                                                       options: .regularExpression)
        if plainText.isEmpty || plainTitle.contains(plainText) { return nil }
        return TextFormat.truncate(text, to: 620)
    }

    /// A summary composed only from facts the app actually measured.
    static func digest(for item: RadarItem) -> String {
        if let repo = item.repo {
            var parts: [String] = []
            let owner = repo.fullName.split(separator: "/").first.map(String.init) ?? repo.fullName
            parts.append("\(repo.fullName) is a\(vowel(owner) ? "n" : "") \(repo.language ?? "public") project by \(owner).")
            parts.append("It has \(TextFormat.number(repo.stars)) stars on GitHub")
            if let today = repo.starsToday, today > 0 {
                parts.append(" and gained \(TextFormat.number(today)) of them in the last 24 hours.")
            } else {
                parts.append(".")
            }
            if let desc = repo.descriptionEN, !desc.isEmpty {
                parts.append(" " + TextFormat.truncate(desc, to: 180))
            }
            if let license = repo.license { parts.append(" Licensed under \(license).") }
            if item.localExecution { parts.append(" It runs locally on this Mac.") }
            return TextFormat.clean(parts.joined())
        }

        let source = item.source.title
        let body = cleanedSourceText(item.rawSummary)
        var parts: [String] = []

        // Name the source and, when it differs, the author. When they are the same
        // ("TLDR … by TLDR") the byline is dropped rather than repeated.
        var opener: String
        switch item.kind {
        case .newsletter:
            opener = "\(source) round-up for \(TextFormat.shortDate(item.published))"
        case .product:
            opener = "\(item.title) is a new product launched on \(source)"
        case .repository, .news:
            // A Tech News story names its own section, and it names it with a
            // real heading rather than empty filler: "A other story from Hacker
            // News" is not a sentence, and "A technology story" says nothing.
            if let section = item.techCategory {
                opener = "\(section.title) story from \(source)"
            } else {
                let topic = item.category.title.lowercased()
                let article = "aeiou".contains(topic.first ?? " ") ? "An" : "A"
                opener = "\(article) \(topic) story from \(source)"
            }
        }
        if let author = item.author, !author.isEmpty, author != source {
            switch item.kind {
            case .product: parts.append(opener + ", built by \(author).")
            default: parts.append(opener + ", by \(author).")
            }
        } else {
            parts.append(opener + ".")
        }
        // Only a real body is used. When there is none, the card shows the
        // opener alone rather than a sentence that promises detail the app does
        // not have: "The original article on Hacker News has the full details"
        // is true of every story ever written and tells the reader nothing.
        if !body.isEmpty, !isPlaceholderText(body),
           !body.lowercased().contains(item.title.lowercased()) {
            parts.append(TextFormat.truncate(body, to: 380))
        } else if item.techCategory != nil {
            // A Tech News story with no body text gets no summary at all.
            //
            // The card already prints the source and the section directly above
            // the headline, so a sentence repeating them — "Developer Tools &
            // Open Source story from Hacker News." — is a line of text that
            // occupies space and says nothing. The card without it is the
            // honest shape of what is known: a headline, a publisher, a time.
            return ""
        } else if item.kind == .newsletter, !item.title.isEmpty {
            // A newsletter issue's own headline is a list of topics; repeating it
            // is the only accurate description of the issue.
            parts.append("This issue covers: \(item.title).")
        }
        if !item.tags.isEmpty {
            parts.append("Filed under \(item.tags.prefix(3).joined(separator: ", ")).")
        }
        if item.free || item.openSource {
            parts.append(item.localExecution
                ? "It is free or open source and runs locally."
                : "It is free or open source.")
        } else if item.paidAPI {
            parts.append("It is a paid API rather than a local tool.")
        }
        if item.appleSilicon && !item.localExecution {
            parts.append("It supports Apple Silicon.")
        }
        // The closing line is a pointer, and a Tech News card already carries
        // the link. Repeating it on every card is the filler that makes a feed
        // look machine-written.
        if item.techCategory == nil {
            parts.append(item.kind == .newsletter
                ? "Every story in the issue is linked from \(source)."
                : "The original article on \(source) has the full details.")
        }
        return TextFormat.clean(parts.joined(separator: " "))
    }

    /// A story title, shortened for use inside a sentence.
    ///
    /// Feed titles can be a paragraph in themselves — a benchmark post is the worst
    /// offender — and a briefing sentence that quotes one verbatim stops being a
    /// sentence. The card still shows the full title.
    static func shortTitle(_ text: String, limit: Int = 90) -> String {
        let clean = sentenceSafe(text)
        guard clean.count > limit else { return clean }
        let clipped = String(clean.prefix(limit))
        // Cut at a word boundary, and never leave a dangling conjunction.
        let trimmed = clipped.split(separator: " ").dropLast().joined(separator: " ")
        return (trimmed.isEmpty ? clipped : trimmed) + "…"
    }

    /// A title inserted mid-sentence must not carry its own closing punctuation,
    /// otherwise "…of all companies." becomes "…of all companies..".
    static func sentenceSafe(_ title: String) -> String {
        var t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = t.last, ".!?".contains(last) {
            t.removeLast()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func vowel(_ s: String) -> Bool {
        guard let c = s.lowercased().first else { return false }
        return "aeiou".contains(c)
    }

    static func splitSentences(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for ch in s {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" {
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(t) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
        return out
    }

    // MARK: - Ollama renderer

    static func prompt(for item: RadarItem) -> String {
        """
        You are a technology editor. Summarise the item below in plain, factual \
        English for a busy reader.

        Rules:
        - 2 to 3 sentences, no marketing language, no speculation.
        - Keep product and company names exactly as written.
        - Only use facts present in the input.

        Input:
        Title: \(item.title)
        Text: \(item.rawSummary.isEmpty ? "(no body text supplied)" : item.rawSummary)
        Source: \(item.source.host)
        \(item.repo.map { "Stars: \($0.stars), language: \($0.language ?? "unknown"), licence: \($0.license ?? "unknown")" } ?? "")

        Reply with this JSON only, no prose around it:
        {"headline": "…", "summary": "…", "points": ["…", "…", "…"]}
        """
    }

    static func ollamaSummary(_ item: RadarItem, config: OllamaConfig) -> Rendered? {
        guard let raw = ModelClient.generate(config: config, prompt: prompt(for: item))
        else { return nil }
        return parseModelJSON(raw)
    }

    /// The model is asked for JSON but may wrap it in prose or markdown fences.
    static func parseModelJSON(_ raw: String) -> Rendered? {
        var text = raw
        if let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}") {
            text = String(text[start...end])
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let headline = (obj["headline"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let summary = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let points = (obj["points"] as? [Any])?.compactMap { $0 as? String } ?? []
        guard !headline.isEmpty || !summary.isEmpty else { return nil }
        return Rendered(headline: headline.isEmpty ? summary : headline,
                        summary: summary,
                        points: points)
    }

    // MARK: - Daily briefing text (offline)

    /// Composes the daily briefing out of the day's items, using only measured
    /// facts. Used when no Ollama model is configured; otherwise
    /// `ollamaBriefing` replaces it.
    ///
    /// News and repositories are scored separately. Ranking them together put a
    /// trending repo above every article, because stars are worth more points than
    /// freshness, and the briefing then read as a GitHub digest. They are now
    /// chosen from their own pools and reported in their own paragraphs.
    static let defaultNewsPicks = 6
    /// The window the briefing counts. Named so the sentence and the filter cannot
    /// drift apart.
    static let hourWindow: Double = 36
    static let defaultRepoPicks = 3

    static func localBriefing(items: [RadarItem], now: Date,
                              previousDayTopIDs: Set<String>,
                              newsPicks: Int = defaultNewsPicks,
                              repoPicks: Int = defaultRepoPicks,
                              rank: RankMode = .fresh) -> DailyBriefing {
        let dayKey = Digest.dayKey(now)
        // The names below shadow these parameters further down, so the counts
        // are captured here under their own names.
        let newsLimit = max(0, newsPicks)
        let repoLimit = max(0, repoPicks)
        // The briefing counts the last 36 hours, and says so in its first sentence.
        let fresh = items.filter { now.timeIntervalSince($0.published) < hourWindow * 3600 }
        let news = fresh.filter { !$0.isGitHub }.sorted { $0.score > $1.score }
        let repos = fresh.filter { $0.isGitHub }
            .sorted { ($0.repo?.stars ?? 0) > ($1.repo?.stars ?? 0) }

        // How many items the briefing shows is a setting: with twenty-four sources
        // six highlights can look arbitrary, and the answer is to make it a choice.
        let topNews = Array(news.prefix(max(0, newsPicks)))
        let repoPicks = Array(repos.prefix(max(0, repoPicks)))

        var counts: [String: Int] = [:]
        for i in news { counts[i.category.rawValue, default: 0] += 1 }
        let orderedCats = Category.allCases
            .compactMap { c -> (Category, Int)? in
                guard let n = counts[c.rawValue], n > 0 else { return nil }
                return (c, n)
            }
            .sorted { $0.1 > $1.1 }

        var paragraphs: [String] = []
        let dateLine = TextFormat.longDate(now)

        // Lead with the news, and say which window the count covers: "today" over a
        // 36-hour window asked the reader to guess why the number looked small next
        // to the item count in the toolbar.
        if !news.isEmpty {
            let sources = Set(news.map { $0.source }).count
            paragraphs.append("\(news.count) new \(news.count == 1 ? "story" : "stories") "
                + "from \(sources) \(sources == 1 ? "source" : "sources") "
                + "in the last \(Int(hourWindow)) hours.")
        } else if !repos.isEmpty {
            paragraphs.append("No new stories today, but \(repos.count) "
                + (repos.count == 1 ? "repository was" : "repositories were") + " trending.")
        } else {
            paragraphs.append("Nothing new was published in the last \(Int(hourWindow)) hours.")
        }

        // "Other" is the classifier's remainder, not a subject. Leading the
        // sentence with "Most of the volume was Other (76)" told the reader the
        // largest bucket was the one nothing landed in.
        let topicCats = orderedCats.filter { $0.0 != .other }
        if let other = orderedCats.first(where: { $0.0 == .other }), other.1 > 0 {
            let tops = topicCats.prefix(3).map { "\($0.0.title) (\($0.1))" }
            if tops.isEmpty {
                paragraphs.append("\(other.1) stories came in, none of them in a topic this app tracks.")
            } else {
                paragraphs.append("Most of the volume was \(tops.joined(separator: ", ")); "
                    + "\(other.1) more did not fit a topic.")
            }
        }
        if let top1 = topNews.first {
            paragraphs.append("Top story: \(shortTitle(top1.displayTitle)) — \(top1.source.title).")
        }
        if topNews.count > 1 {
            let rest = topNews.dropFirst().prefix(min(2, max(1, topNews.count - 1)))
                .map { shortTitle($0.displayTitle, limit: 70) }
            paragraphs.append("Also worth reading: \(rest.joined(separator: "; ")).")
        }

        // Already named above, so it is not named again: a story that appeared in
        // "Top story" or "Also worth reading" is not repeated here.
        let named = Set(topNews.prefix(4).map { $0.id })
        let freeLocal = news.filter {
            ($0.free || $0.openSource) && ($0.localExecution || $0.appleSilicon)
                && !named.contains($0.id)
        }
        if !freeLocal.isEmpty {
            let names = freeLocal.prefix(3).map { shortTitle($0.displayTitle, limit: 60) }
                .joined(separator: "; ")
            paragraphs.append("Also runs locally on this Mac: \(names).")
        } else {
            let freeOnes = news.filter { $0.free || $0.openSource }
            if !freeOnes.isEmpty {
                paragraphs.append("\(freeOnes.count) of today's stories "
                    + (freeOnes.count == 1 ? "is free or open source." : "are free or open source."))
            }
        }

        // Repository activity gets its own paragraph and its own section, rather
        // than competing with the news for the highlight slots.
        if let r = repoPicks.first, let stats = r.repo {
            var line = "Trending on GitHub: \(stats.fullName), "
                + "\(TextFormat.number(stats.stars)) stars"
            if let today = stats.starsToday, today > 0 {
                line += " (+\(TextFormat.number(today)) today)"
            }
            if let lang = stats.language { line += ", \(lang)" }
            paragraphs.append(line + ".")
        }
        if repoPicks.count > 1 {
            let names = repoPicks.dropFirst().compactMap { $0.repo?.fullName }
            if !names.isEmpty {
                paragraphs.append("Also trending: \(names.joined(separator: ", ")).")
            }
        }

        if !previousDayTopIDs.isEmpty && !topNews.isEmpty {
            let changed = topNews.filter { !previousDayTopIDs.contains($0.id) }
            paragraphs.append(changed.isEmpty
                ? "The top of the list is unchanged from yesterday."
                : "\(changed.count) of the top stories are new since yesterday.")
        }

        // Every surface gets its own picks, so the home page can show a block
        // per tab. A reader who follows the web and SEO side should not have to
        // scroll past forty AI headlines to reach it.
        var sectionPicks: [String: [String]] = [:]
        var sectionCounts: [String: Int] = [:]
        for section in BriefingSection.allCases {
            let pool = fresh.filter { BriefingSection.section(for: $0) == section }
            sectionCounts[section.rawValue] = pool.count
            // Within a surface, the app's ranking decides.
            let ordered = Filtering.rank(pool, by: rank, appleSiliconFirst: true)
            let limit = section == .code ? repoLimit : newsLimit
            sectionPicks[section.rawValue] = Array(ordered.prefix(limit)).map { $0.id }
        }

        return DailyBriefing(dayKey: dayKey,
                             generatedAt: now,
                             headline: dateLine,
                             paragraphs: paragraphs,
                             highlightIDs: topNews.map { $0.id },
                             repoPickIDs: repoPicks.map { $0.id },
                             sectionPickIDs: sectionPicks,
                             sectionCounts: sectionCounts,
                             categoryCounts: counts,
                             engine: "local",
                             newsCount: news.count,
                             sourceCount: Set(news.map { $0.source }).count,
                             revision: Digest.revision)
    }

    static func ollamaBriefing(items: [RadarItem], now: Date,
                               config: OllamaConfig,
                               newsPicks: Int = defaultNewsPicks,
                               repoPicks: Int = defaultRepoPicks,
                               rank: RankMode = .fresh) -> DailyBriefing? {
        // The model sees news only; repository activity is summarised from
        // measured numbers by `localBriefing`, which a model cannot improve on.
        let fresh = items.filter {
            now.timeIntervalSince($0.published) < hourWindow * 3600 && !$0.isGitHub
        }
        let top = Array(fresh.sorted { $0.score > $1.score }.prefix(10))
        guard !top.isEmpty else { return nil }
        let lines = top.map { "- \($0.title) [\($0.source.host)]" }.joined(separator: "\n")
        let prompt = """
        You are the editor of a daily technology briefing. Using only the list \
        below, write three to five short paragraphs in plain English about the \
        most important items and the practical tools worth trying. No headings, \
        no bullet points, no speculation beyond the list.

        Today's items:
        \(lines)

        Reply with the briefing text only.
        """
        guard let raw = ModelClient.generate(config: config, prompt: prompt),
              raw.trimmingCharacters(in: .whitespacesAndNewlines).count > 40
        else { return nil }
        let paras = raw.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let local = localBriefing(items: items, now: now, previousDayTopIDs: [],
                                  newsPicks: newsPicks, repoPicks: repoPicks,
                                  rank: rank)
        return DailyBriefing(dayKey: local.dayKey,
                             generatedAt: now,
                             headline: local.headline,
                             paragraphs: paras,
                             highlightIDs: local.highlightIDs,
                             repoPickIDs: local.repoPickIDs,
                             sectionPickIDs: local.sectionPickIDs,
                             sectionCounts: local.sectionCounts,
                             categoryCounts: local.categoryCounts,
                             engine: config.engineTag,
                             newsCount: local.newsCount,
                             sourceCount: local.sourceCount,
                             revision: Digest.revision)
    }
}

/// The daily briefing shown on the first tab.
struct DailyBriefing: Codable, Hashable {
    var dayKey: String
    var generatedAt: Date
    var headline: String
    var paragraphs: [String]
    var highlightIDs: [String]
    var repoPickIDs: [String]
    /// The picks of each reading surface, so the home page can show a block per
    /// tab instead of one list of whatever happened to rank highest.
    var sectionPickIDs: [String: [String]] = [:]
    /// How many stories each surface contributed in the window.
    var sectionCounts: [String: Int] = [:]
    var categoryCounts: [String: Int]
    var engine: String
    /// The two numbers the briefing quotes in its first sentence. Stored so the
    /// card can show them as figures; a view that recomputed them from the item
    /// list could disagree with the sentence next to it.
    var newsCount: Int? = nil
    var sourceCount: Int? = nil
    /// Which generator wrote this. A stored briefing older than the current
    /// generator is rebuilt instead of shown: derived data that outlives the code
    /// that produced it shows bugs that have already been fixed.
    var revision: Int? = nil
}

enum Digest {
    /// Bumped whenever the briefing text changes shape, so a stored briefing
    /// written by the previous generator is not shown as if it were current.
    static let revision = 3

    static func dayKey(_ d: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
