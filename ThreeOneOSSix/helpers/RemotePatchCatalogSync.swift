import Combine
import Foundation

struct PatchHubPatch: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let description: String?
    let maintenance: Bool
    let packageURL: String
    let packageFilename: String
    let packageSize: Int
    let iconURL: String?
    let catalogVersion: Int
    let updatedAt: String?
}

struct PatchHubCatalog: Codable, Equatable {
    let catalogVersion: Int
    let updatedAt: String?
    let patches: [PatchHubPatch]
}

enum PatchHubSyncPhase: Equatable {
    case idle
    case syncing
    case synced
    case offline
    case blocked
}

struct PatchHubSyncNotice: Identifiable, Equatable {
    let id = UUID()
    let messageKey: String
    let argument: String?
}

@MainActor
final class RemotePatchCatalogSync: ObservableObject {
    static let sourceName = "PatchHub 3106"
    private static let cacheDirectoryName = "PatchHub"
    private static let catalogCacheFilename = "catalog.json"
    private static let etagFilename = "catalog.etag"
    private static let seenFilename = "seen.json"
    private static let userAgent = "3106-PatchHub/1"
    private static let maximumPackageBytes = 25 * 1_024 * 1_024

    @Published private(set) var catalog: PatchHubCatalog?
    @Published private(set) var phase: PatchHubSyncPhase = .idle
    @Published private(set) var isStale = false
    @Published private(set) var lastSuccessfulSync: Date?
    @Published private(set) var activePatchIDs = Set<UUID>()
    @Published private(set) var protectedRemotePatchIDs = Set<String>()
    @Published var notice: PatchHubSyncNotice?

    private struct SeenPatch: Codable, Equatable {
        let packageURL: String
        let updatedAt: String?
        let catalogVersion: Int
    }

    private var seen: [String: SeenPatch] = [:]
    private var etag: String?
    private var pollTask: Task<Void, Never>?
    private var eventTask: Task<Void, Never>?
    private weak var patchStore: PatchProjectStore?
    private var isRequestInFlight = false
    private var hasLoadedCache = false

    init() {
        loadCache()
    }

    var configuredCatalogURL: URL? {
        let override = UserDefaults.standard.string(forKey: "PatchHubCatalogURL")
        let configured = override ?? Bundle.main.object(
            forInfoDictionaryKey: "PatchHubCatalogURL"
        ) as? String
        guard let configured,
              let url = URL(string: configured),
              (try? PackageRepositoryURLPolicy.validate(url)) != nil else {
            return nil
        }
        return url
    }

    func start(using patchStore: PatchProjectStore) {
        self.patchStore = patchStore
        loadCacheIfNeeded()
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            guard let self else { return }
            await self.synchronizeNow()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { break }
                await self.synchronizeNow()
            }
        }

        eventTask = Task { [weak self] in
            await self?.listenForEvents()
        }
    }

    func stop() {
        pollTask?.cancel()
        eventTask?.cancel()
        pollTask = nil
        eventTask = nil
    }

    func refreshNow() {
        Task { [weak self] in
            await self?.synchronizeNow()
        }
    }

    func remotePatch(for item: PatchLibraryItem) -> PatchHubPatch? {
        guard let origin = item.origin,
              origin.repositoryName == Self.sourceName else {
            return catalog?.patches.first { $0.id.caseInsensitiveCompare(item.id.uuidString) == .orderedSame }
        }
        return catalog?.patches.first {
            $0.id.caseInsensitiveCompare(origin.packageIdentifier) == .orderedSame
        }
    }

    func resolvedURL(_ rawValue: String?) -> URL? {
        guard let rawValue,
              let catalogURL = configuredCatalogURL,
              let resolved = URL(string: rawValue, relativeTo: catalogURL)?.absoluteURL,
              (try? PackageRepositoryURLPolicy.validate(resolved)) != nil else {
            return nil
        }
        return resolved
    }

    private func synchronizeNow() async {
        guard !isRequestInFlight else { return }
        guard let catalogURL = configuredCatalogURL else {
            phase = .offline
            isStale = true
            return
        }
        isRequestInFlight = true
        phase = .syncing
        defer { isRequestInFlight = false }

        do {
            var request = URLRequest(url: catalogURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            if let etag {
                request.setValue(etag, forHTTPHeaderField: "If-None-Match")
            }

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw PatchHubSyncError.invalidResponse
            }
            if httpResponse.statusCode == 304 {
                lastSuccessfulSync = Date()
                isStale = false
                phase = .synced
                return
            }
            guard (200..<300).contains(httpResponse.statusCode) else {
                throw PatchHubSyncError.http(httpResponse.statusCode)
            }

            let decoded = try JSONDecoder().decode(PatchHubCatalog.self, from: data)
            catalog = decoded
            etag = httpResponse.value(forHTTPHeaderField: "ETag") ?? etag
            persistCache(decoded)
            lastSuccessfulSync = Date()
            isStale = false
            phase = .synced
            await reconcile(decoded)
        } catch is CancellationError {
            return
        } catch {
            phase = .offline
            isStale = true
            log("patchhub: catalog unavailable — \(error.localizedDescription)")
        }
    }

    private func listenForEvents() async {
        guard let catalogURL = configuredCatalogURL,
              let eventsURL = eventsURL(for: catalogURL) else { return }

        var retryNanoseconds: UInt64 = 1_000_000_000
        while !Task.isCancelled {
            do {
                var request = URLRequest(url: eventsURL)
                request.timeoutInterval = 60
                request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode) else {
                    throw PatchHubSyncError.invalidResponse
                }
                retryNanoseconds = 1_000_000_000
                for try await line in bytes.lines {
                    guard !Task.isCancelled else { return }
                    if line == "data: {\"catalogVersion\":" || line.hasPrefix("data:") {
                        await synchronizeNow()
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                try? await Task.sleep(nanoseconds: retryNanoseconds)
                retryNanoseconds = min(retryNanoseconds * 2, 30_000_000_000)
            }
        }
    }

    private func reconcile(_ remoteCatalog: PatchHubCatalog) async {
        guard let patchStore else { return }
        let deadline = Date().addingTimeInterval(10)
        while patchStore.isBusy, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard !patchStore.isBusy else { return }

        var activeIDs = Set<UUID>()
        var protectedIDs = Set<String>()
        let remoteIDs = Set(remoteCatalog.patches.map { $0.id.lowercased() })

        for remotePatch in remoteCatalog.patches {
            guard !Task.isCancelled else { return }
            let local = patchStore.items.first { item in
                guard let origin = item.origin,
                      origin.repositoryName == Self.sourceName else { return false }
                return origin.packageIdentifier.caseInsensitiveCompare(remotePatch.id) == .orderedSame
            }

            if let local {
                if let receipt = DevicePatchService.latestReceipt(projectID: local.id) {
                    _ = receipt
                    activeIDs.insert(local.id)
                }
                let shouldCheckPackage = shouldRefreshPackage(remotePatch)
                if shouldCheckPackage {
                    if activeIDs.contains(local.id) {
                        protectedIDs.insert(remotePatch.id)
                        if !protectedRemotePatchIDs.contains(remotePatch.id) {
                            notice = PatchHubSyncNotice(
                                messageKey: "patchhub.update_blocked",
                                argument: remotePatch.name
                            )
                        }
                    } else {
                        if await downloadAndImport(
                            remotePatch,
                            replacing: local,
                            patchStore: patchStore
                        ) {
                            markSeen(remotePatch)
                        }
                    }
                } else {
                    markSeen(remotePatch)
                }
                continue
            }

            if await downloadAndImport(remotePatch, replacing: nil, patchStore: patchStore) {
                markSeen(remotePatch)
            }
        }

        for local in patchStore.items {
            guard let origin = local.origin,
                  origin.repositoryName == Self.sourceName,
                  !remoteIDs.contains(origin.packageIdentifier.lowercased()) else { continue }
            if DevicePatchService.latestReceipt(projectID: local.id) != nil {
                activeIDs.insert(local.id)
                protectedIDs.insert(origin.packageIdentifier)
                notice = PatchHubSyncNotice(
                    messageKey: "patchhub.removal_blocked",
                    argument: local.project?.name ?? origin.packageIdentifier
                )
            } else {
                patchStore.delete(local)
            }
        }

        activePatchIDs = activeIDs
        protectedRemotePatchIDs = protectedIDs
        persistSeen()
    }

    private func shouldRefreshPackage(_ remotePatch: PatchHubPatch) -> Bool {
        guard let old = seen[remotePatch.id] else { return false }
        return old.packageURL != remotePatch.packageURL || old.updatedAt != remotePatch.updatedAt
    }

    @discardableResult
    private func downloadAndImport(
        _ remotePatch: PatchHubPatch,
        replacing local: PatchLibraryItem?,
        patchStore: PatchProjectStore
    ) async -> Bool {
        guard let packageURL = resolvedURL(remotePatch.packageURL) else {
            log("patchhub: rejected package URL for \(remotePatch.id)")
            return false
        }
        do {
            let repositoryPackage = RepositoryPackage(
                identifier: remotePatch.id,
                kind: .patch,
                name: remotePatch.name,
                author: Self.sourceName,
                version: remotePatch.updatedAt ?? "catalog-\(remotePatch.catalogVersion)",
                summary: remotePatch.description ?? remotePatch.name,
                details: remotePatch.description,
                category: "PatchHub",
                tags: ["PatchHub"],
                publishedAt: nil,
                iconURL: resolvedURL(remotePatch.iconURL),
                bannerURL: nil,
                screenshotURLs: [],
                downloadURL: packageURL,
                sha256: nil,
                expectedSize: UInt64(max(remotePatch.packageSize, 0)),
                supportedOS: [],
                changelog: nil,
                isFeatured: false,
                isPrivate: false,
                sharedPassword: nil
            )
            let data = try await PackageRepositoryNetworkClient.download(repositoryPackage)
            let summary = try PatchPackageCodec.inspect(data)
            if let local, summary.packageID != local.id {
                notice = PatchHubSyncNotice(
                    messageKey: "patchhub.identity_blocked",
                    argument: remotePatch.name
                )
                log("patchhub: blocked identity change for \(remotePatch.id)")
                return false
            }
            let origin = PatchPackageOrigin(
                repositoryName: Self.sourceName,
                repositoryURL: configuredCatalogURL ?? packageURL,
                packageIdentifier: remotePatch.id
            )
            guard patchStore.importPackage(data: data, password: nil, origin: origin) else {
                return false
            }
            let deadline = Date().addingTimeInterval(20)
            while patchStore.isBusy, Date() < deadline, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if patchStore.passwordRequest != nil {
                notice = PatchHubSyncNotice(
                    messageKey: "patchhub.password_required",
                    argument: remotePatch.name
                )
            }
            return true
        } catch {
            log("patchhub: package import failed for \(remotePatch.id) — \(error.localizedDescription)")
            return false
        }
    }

    private func eventsURL(for catalogURL: URL) -> URL? {
        guard var components = URLComponents(url: catalogURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/api/mobile/patches/events"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func loadCacheIfNeeded() {
        guard !hasLoadedCache else { return }
        hasLoadedCache = true
        let fileManager = FileManager.default
        guard let directory = try? cacheDirectory(fileManager: fileManager) else { return }
        if let data = try? Data(contentsOf: directory.appendingPathComponent(Self.catalogCacheFilename)),
           let cached = try? JSONDecoder().decode(PatchHubCatalog.self, from: data) {
            catalog = cached
            isStale = true
        }
        if let value = try? String(
            contentsOf: directory.appendingPathComponent(Self.etagFilename),
            encoding: .utf8
        ) {
            etag = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let data = try? Data(contentsOf: directory.appendingPathComponent(Self.seenFilename)),
           let decoded = try? JSONDecoder().decode([String: SeenPatch].self, from: data) {
            seen = decoded
        }
    }

    private func loadCache() {
        loadCacheIfNeeded()
    }

    private func persistCache(_ value: PatchHubCatalog) {
        guard let directory = try? cacheDirectory(fileManager: .default) else { return }
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(
                to: directory.appendingPathComponent(Self.catalogCacheFilename),
                options: [.atomic, .completeFileProtection]
            )
        }
        if let etag, let data = etag.data(using: .utf8) {
            try? data.write(
                to: directory.appendingPathComponent(Self.etagFilename),
                options: [.atomic, .completeFileProtection]
            )
        }
    }

    private func markSeen(_ patch: PatchHubPatch) {
        seen[patch.id] = SeenPatch(
            packageURL: patch.packageURL,
            updatedAt: patch.updatedAt,
            catalogVersion: patch.catalogVersion
        )
    }

    private func persistSeen() {
        guard let directory = try? cacheDirectory(fileManager: .default),
              let data = try? JSONEncoder().encode(seen) else { return }
        try? data.write(
            to: directory.appendingPathComponent(Self.seenFilename),
            options: [.atomic, .completeFileProtection]
        )
    }

    private func cacheDirectory(fileManager: FileManager) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = applicationSupport.appendingPathComponent(
            Self.cacheDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

enum PatchHubSyncError: LocalizedError {
    case invalidResponse
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "PatchHub returned an invalid response"
        case .http(let status): return "PatchHub HTTP \(status)"
        }
    }
}
