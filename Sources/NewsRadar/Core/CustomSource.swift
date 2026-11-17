import Foundation

/// A feed the user added from inside the app.
///
/// Built-in sources live in code because they were chosen by hand and each has a
/// bespoke collector. A custom source cannot be like that: it has to be stored,
/// validated before it is trusted, and shown with the same authority as a built-in
/// one. This type is that record.
struct CustomSource: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    /// The feed that actually answered, which may differ from what was typed when
    /// the site advertises its feed through a <link rel="alternate"> tag.
    var feedURL: String
    var homeURL: String
    var host: String
    var symbol: String = "antenna.radiowaves.left.and.right"
    var accentHex: String = "#8C3A46"
    var addedAt: Date
    /// How many entries the feed had the last time it was checked.
    var itemCount: Int = 0
    /// The last validation message, kept so the list can explain a source that
    /// used to work and no longer does.
    var note: String = ""

    var sourceID: SourceID { SourceID.custom(id) }

    var spec: SourceSpec {
        SourceSpec(title: title, host: host, homeURL: homeURL, feedURL: feedURL,
                   access: .rss, symbol: symbol, accentHex: accentHex,
                   accessDescription: "RSS / Atom feed you added")
    }
}

/// The list of user-added sources, held in memory and backed by `Store`.
///
/// It is a singleton because the fetch engine runs on background queues and has to
/// resolve a `SourceID` to its feed URL without being handed state. Reads and
/// writes take a lock; the list is small and changes only when the user adds or
/// removes a source.
final class SourceRegistry {
    static let shared = SourceRegistry()

    private let lock = NSLock()
    private var storage: [CustomSource] = []
    private var byID: [String: CustomSource] = [:]

    private init() {}

    var all: [CustomSource] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func source(for id: SourceID) -> CustomSource? {
        lock.lock(); defer { lock.unlock() }
        return byID[id.rawValue]
    }

    func replaceAll(_ sources: [CustomSource]) {
        lock.lock(); defer { lock.unlock() }
        // Deduplicated on the way in. A sources file written twice, or restored
        // from a backup, can carry the same row twice; keeping both would draw
        // the source twice and, before the map below stopped asserting, trap the
        // process on launch.
        var seen = Set<String>()
        storage = sources.filter { seen.insert($0.sourceID.rawValue).inserted }
        // Not `uniqueKeysWithValues`: two rows can carry the same id after a
        // hand-edited or restored sources file, and that traps the process on
        // launch. Last one wins, which is what the list already shows.
        byID = Dictionary(storage.map { ($0.sourceID.rawValue, $0) },
                          uniquingKeysWith: { _, later in later })
    }

    @discardableResult
    func add(_ source: CustomSource) -> Bool {
        lock.lock(); defer { lock.unlock() }
        // One feed, one row: adding the same URL twice would double every story.
        guard !storage.contains(where: { $0.feedURL.caseInsensitiveCompare(source.feedURL) == .orderedSame })
        else { return false }
        storage.append(source)
        byID[source.sourceID.rawValue] = source
        return true
    }

    func remove(_ id: String) -> CustomSource? {
        lock.lock(); defer { lock.unlock() }
        guard let idx = storage.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = storage.remove(at: idx)
        byID[removed.sourceID.rawValue] = nil
        return removed
    }
}

extension SourceID {
    /// The twenty-four sources that ship with the app, in reading order.
    static let builtIns: [SourceID] = SourceID.publishers + SourceID.labs
        + SourceID.community + SourceID.design + SourceID.code

    /// The Tech News tab's publishers, as ordinary sources.
    static var techSources: [SourceID] {
        TechCatalogue.sources.map { $0.sourceID }
    }

    /// The design tab's feeds, as ordinary sources.
    ///
    /// They join the same refresh pass, so one fetch serves both tabs: a story
    /// that appears in the news list and in design is stored once.
    static var designSources: [SourceID] {
        DesignCatalogue.sources.map { $0.sourceID ?? SourceID.design($0.id) }
    }

    /// Everything the app collects: built-ins, the design feeds, then what the
    /// user added.
    ///
    /// A publisher the app already collected — Creative Bloq, It's Nice That —
    /// is collected once and read in the design tab, so it is not listed twice.
    static var all: [SourceID] {
        let built = Set(builtIns)
        let extra = designSources.filter { !built.contains($0) }
        // The Tech News tab's publishers are collected by the same pass, so one
        // fetch serves every tab: a story that appears in the news list and in
        // the tech list is stored once.
        let tech = techSources.filter { !built.contains($0) && !extra.contains($0) }
        return builtIns + extra + tech + SourceRegistry.shared.all.map { $0.sourceID }
    }

    /// Whether this is a source the app ships with.
    var isBuiltIn: Bool { SourceID.builtIns.contains(self) }

    /// The spec for a user-added source, or nil when the id is not one.
    static func customSpec(for id: SourceID) -> SourceSpec? {
        SourceRegistry.shared.source(for: id)?.spec
    }
}
