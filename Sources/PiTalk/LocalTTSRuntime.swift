import Foundation
import Darwin

final class LocalTTSRuntime {
    static let shared = LocalTTSRuntime()

    private let lock = NSLock()
    private var serverProcess: Process?
    private var isDownloading = false

    private let host = "127.0.0.1"
    private let port = 18083

    // Pinned Pocket TTS repo/revision layout (same strategy as Loqui)
    private let mainRepo = "models--kyutai--pocket-tts"
    private let mainRevision = "427e3d61b276ed69fdd03de0d185fa8a8d97fc5b"

    private let noCloneRepo = "models--kyutai--pocket-tts-without-voice-cloning"
    private let tokenizerRevision = "d4fdd22ae8c8e1cb3634e150ebeff1dab2d16df3"
    private let embeddingsRevision = "2578fed2380333b621689eaed6fe144cf69dfeb3"

    // Model asset hosted alongside PiTalk DMG on GitHub Releases
    private let releaseOwner = "swairshah"
    private let releaseRepo = "PiTalk"

    private init() {}

    enum RuntimeError: LocalizedError {
        case binaryNotFound
        case modelNotInstalled
        case modelDownloadInProgress
        case modelDownloadFailed(String)
        case serverStartFailed
        case serverRequestFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "Local runtime binary not found. Reinstall PiTalk or install pocket-tts-cli."
            case .modelNotInstalled:
                return "Local model not downloaded yet. Open Settings and download it first."
            case .modelDownloadInProgress:
                return "Model download already in progress."
            case .modelDownloadFailed(let message):
                return "Failed to download local model: \(message)"
            case .serverStartFailed:
                return "Failed to start local TTS runtime."
            case .serverRequestFailed(let message):
                return message
            }
        }
    }

    func isRuntimeAvailable() -> Bool {
        resolveRuntimeBinaryURL() != nil
    }

    func isModelInstalled() -> Bool {
        hasCachedModelFiles() || hasBundledModelFiles() || hasDownloadedModelFiles()
    }

    func modelCachePath() -> String {
        modelCacheDirectory().path
    }

    func downloadedModelsPath() -> String {
        downloadedModelsDirectory().path
    }

    func downloadModelIfNeeded(preferredVoice _: String) async throws {
        guard isRuntimeAvailable() else {
            throw RuntimeError.binaryNotFound
        }

        if hasCachedModelFiles() {
            return
        }

        // If a full app package ships bundled models, seed cache from those first (offline).
        if hasBundledModelFiles() {
            setupBundledModelsCacheIfAvailable()
            if hasCachedModelFiles() {
                return
            }
        }

        // If we've already downloaded raw model files before, try seeding from them.
        if hasDownloadedModelFiles() {
            setupDownloadedModelsCacheIfAvailable()
            if hasCachedModelFiles() {
                return
            }
        }

        guard beginDownload() else {
            throw RuntimeError.modelDownloadInProgress
        }

        defer { endDownload() }

        try await downloadModelsFromReleaseAsset()
        setupDownloadedModelsCacheIfAvailable()

        guard hasCachedModelFiles() else {
            throw RuntimeError.modelDownloadFailed("Downloaded model archive, but required files were not found after extraction")
        }
    }

    func synthesize(text: String, voice: String) async throws -> Data {
        guard isModelInstalled() else {
            throw RuntimeError.modelNotInstalled
        }

        try await ensureServerRunning()

        let url = URL(string: "http://\(host):\(port)/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "text": text,
            "voice": voice
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw RuntimeError.serverRequestFailed("Invalid local runtime response.")
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw RuntimeError.serverRequestFailed("Local runtime error (\(httpResponse.statusCode)): \(message)")
        }

        return data
    }

    func stopServer() {
        let process: Process? = {
            lock.lock()
            defer { lock.unlock() }
            let p = serverProcess
            serverProcess = nil
            return p
        }()

        guard let process else { return }
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                if process.isRunning {
                    kill(pid, SIGKILL)
                }
            }
        }
    }

    private func ensureServerRunning() async throws {
        if !hasCachedModelFiles() {
            if hasBundledModelFiles() {
                setupBundledModelsCacheIfAvailable()
            } else if hasDownloadedModelFiles() {
                setupDownloadedModelsCacheIfAvailable()
            }
        }

        guard hasCachedModelFiles() else {
            throw RuntimeError.modelNotInstalled
        }

        if let process = currentServerProcess(), process.isRunning, await isServerHealthy() {
            return
        }

        stopServer()

        guard let runtime = resolveRuntimeBinaryURL() else {
            throw RuntimeError.binaryNotFound
        }

        let process = Process()
        process.executableURL = runtime
        process.arguments = [
            "serve",
            "--host", host,
            "--port", "\(port)",
            "--voice", "alba",
            "--prewarm-voices", "alba",
            "--warmup", "true"
        ]
        if let cwd = prepareRuntimeWorkingDirectory() {
            process.currentDirectoryURL = cwd
        }
        process.environment = runtimeEnvironment()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            self?.clearServerProcess()
        }

        do {
            try process.run()
        } catch {
            throw RuntimeError.serverStartFailed
        }

        setServerProcess(process)

        for _ in 0..<50 {
            if await isServerHealthy() {
                return
            }
            if !process.isRunning {
                break
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        stopServer()
        throw RuntimeError.serverStartFailed
    }

    private func isServerHealthy() async -> Bool {
        let url = URL(string: "http://\(host):\(port)/health")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func downloadModelsFromReleaseAsset() async throws {
        let assetURL = try modelAssetURL()

        let (archiveURL, response) = try await URLSession.shared.download(from: assetURL)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RuntimeError.modelDownloadFailed("Model asset not available at \(assetURL.absoluteString) (HTTP \(http.statusCode))")
        }

        let fm = FileManager.default
        let stagingDir = fm.temporaryDirectory.appendingPathComponent("pitalk-model-stage-\(UUID().uuidString)")
        try? fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: stagingDir)
            try? fm.removeItem(at: archiveURL)
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-q", "-o", archiveURL.path, "-d", stagingDir.path]
        let stderrPipe = Pipe()
        unzip.standardError = stderrPipe

        do {
            try unzip.run()
            unzip.waitUntilExit()
        } catch {
            throw RuntimeError.modelDownloadFailed("Could not extract model archive: \(error.localizedDescription)")
        }

        guard unzip.terminationStatus == 0 else {
            let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let err = String(data: errData, encoding: .utf8) ?? "unzip failed"
            throw RuntimeError.modelDownloadFailed(err)
        }

        guard let extractedModelsDir = locateExtractedModelsDir(in: stagingDir) else {
            throw RuntimeError.modelDownloadFailed("Archive did not contain expected model files")
        }

        let destination = downloadedModelsDirectory()
        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: extractedModelsDir, to: destination)
    }

    private func modelAssetURL() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["PITALK_LOCAL_MODEL_URL"],
           let url = URL(string: override), !override.isEmpty {
            return url
        }

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
            ?? ""

        guard !version.isEmpty else {
            throw RuntimeError.modelDownloadFailed("Could not determine app version for model download URL")
        }

        let urlString = "https://github.com/\(releaseOwner)/\(releaseRepo)/releases/download/v\(version)/PiTalk-models-\(version).zip"
        guard let url = URL(string: urlString) else {
            throw RuntimeError.modelDownloadFailed("Invalid model download URL")
        }
        return url
    }

    private func setupBundledModelsCacheIfAvailable() {
        guard let bundled = bundledModelsDirectory() else { return }
        seedCache(fromModelsRoot: bundled)
    }

    private func setupDownloadedModelsCacheIfAvailable() {
        let downloaded = downloadedModelsDirectory()
        guard FileManager.default.fileExists(atPath: downloaded.path) else { return }
        seedCache(fromModelsRoot: downloaded)
    }

    private func seedCache(fromModelsRoot modelsRoot: URL) {
        let fm = FileManager.default
        let hubDir = modelCacheDirectory().appendingPathComponent("hub")

        let mainWeights = modelsRoot.appendingPathComponent("tts_b6369a24.safetensors")
        if fm.fileExists(atPath: mainWeights.path) {
            seedCacheFile(
                source: mainWeights,
                repo: mainRepo,
                revision: mainRevision,
                snapshotPath: "tts_b6369a24.safetensors",
                blobName: "tts_b6369a24.safetensors",
                hubDir: hubDir
            )
        }

        let tokenizer = modelsRoot.appendingPathComponent("tokenizer.model")
        if fm.fileExists(atPath: tokenizer.path) {
            seedCacheFile(
                source: tokenizer,
                repo: noCloneRepo,
                revision: tokenizerRevision,
                snapshotPath: "tokenizer.model",
                blobName: "tokenizer.model",
                hubDir: hubDir
            )
        }

        let embeddingsDir = modelsRoot.appendingPathComponent("embeddings")
        if let files = try? fm.contentsOfDirectory(at: embeddingsDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "safetensors" {
                let name = file.lastPathComponent
                seedCacheFile(
                    source: file,
                    repo: noCloneRepo,
                    revision: embeddingsRevision,
                    snapshotPath: "embeddings/\(name)",
                    blobName: name,
                    hubDir: hubDir
                )
            }
        }
    }

    private func seedCacheFile(source: URL,
                               repo: String,
                               revision: String,
                               snapshotPath: String,
                               blobName: String,
                               hubDir: URL) {
        let fm = FileManager.default
        let repoDir = hubDir.appendingPathComponent(repo)
        let blobsDir = repoDir.appendingPathComponent("blobs")
        let snapshotDir = repoDir.appendingPathComponent("snapshots").appendingPathComponent(revision)

        try? fm.createDirectory(at: blobsDir, withIntermediateDirectories: true)

        let snapshotFile = snapshotDir.appendingPathComponent(snapshotPath)
        try? fm.createDirectory(at: snapshotFile.deletingLastPathComponent(), withIntermediateDirectories: true)

        let blobURL = blobsDir.appendingPathComponent(blobName)
        if !fm.fileExists(atPath: blobURL.path) {
            try? fm.copyItem(at: source, to: blobURL)
        }

        if !fm.fileExists(atPath: snapshotFile.path) {
            let relative = "../../blobs/\(blobName)"
            try? fm.createSymbolicLink(atPath: snapshotFile.path, withDestinationPath: relative)
        }
    }

    private func locateExtractedModelsDir(in stagingDir: URL) -> URL? {
        let fm = FileManager.default

        let direct = stagingDir.appendingPathComponent("models")
        if hasRawModelFiles(in: direct) {
            return direct
        }

        guard let enumerator = fm.enumerator(at: stagingDir, includingPropertiesForKeys: nil) else {
            return nil
        }

        for case let fileURL as URL in enumerator where fileURL.lastPathComponent == "tts_b6369a24.safetensors" {
            let parent = fileURL.deletingLastPathComponent()
            if hasRawModelFiles(in: parent) {
                return parent
            }
        }

        return nil
    }

    private func hasRawModelFiles(in modelsRoot: URL) -> Bool {
        let fm = FileManager.default
        let weights = modelsRoot.appendingPathComponent("tts_b6369a24.safetensors")
        let tokenizer = modelsRoot.appendingPathComponent("tokenizer.model")
        let embeddings = modelsRoot.appendingPathComponent("embeddings")

        guard fm.fileExists(atPath: weights.path),
              fm.fileExists(atPath: tokenizer.path),
              fm.fileExists(atPath: embeddings.path),
              directoryContainsFiles(embeddings) else {
            return false
        }

        return true
    }

    private func currentServerProcess() -> Process? {
        lock.lock()
        defer { lock.unlock() }
        return serverProcess
    }

    private func setServerProcess(_ process: Process) {
        lock.lock()
        serverProcess = process
        lock.unlock()
    }

    private func clearServerProcess() {
        lock.lock()
        serverProcess = nil
        lock.unlock()
    }

    private func beginDownload() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isDownloading else { return false }
        isDownloading = true
        return true
    }

    private func endDownload() {
        lock.lock()
        isDownloading = false
        lock.unlock()
    }

    private func runtimeEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = modelCacheDirectory().path

        if let embeddingsDir = activeEmbeddingsDirectory() {
            env["POCKET_TTS_VOICES_DIR"] = embeddingsDir.path
        }

        return env
    }

    private func modelCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("PiTalk")
            .appendingPathComponent("local-tts")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private func downloadedModelsDirectory() -> URL {
        modelCacheDirectory().appendingPathComponent("downloaded-models")
    }

    private func bundledModelsDirectory() -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let models = URL(fileURLWithPath: resourcePath).appendingPathComponent("models")
        return hasRawModelFiles(in: models) ? models : nil
    }

    private func hasBundledModelFiles() -> Bool {
        bundledModelsDirectory() != nil
    }

    private func hasDownloadedModelFiles() -> Bool {
        hasRawModelFiles(in: downloadedModelsDirectory())
    }

    private func activeEmbeddingsDirectory() -> URL? {
        let downloaded = downloadedModelsDirectory().appendingPathComponent("embeddings")
        if directoryContainsFiles(downloaded) {
            return downloaded
        }

        if let bundled = bundledModelsDirectory() {
            let embeddings = bundled.appendingPathComponent("embeddings")
            if directoryContainsFiles(embeddings) {
                return embeddings
            }
        }

        return nil
    }

    private func hasCachedModelFiles() -> Bool {
        let fm = FileManager.default
        let hub = modelCacheDirectory().appendingPathComponent("hub")

        let weightsSnapshot = hub
            .appendingPathComponent(mainRepo)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(mainRevision)
            .appendingPathComponent("tts_b6369a24.safetensors")

        let tokenizerSnapshot = hub
            .appendingPathComponent(noCloneRepo)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(tokenizerRevision)
            .appendingPathComponent("tokenizer.model")

        let embeddingsSnapshot = hub
            .appendingPathComponent(noCloneRepo)
            .appendingPathComponent("snapshots")
            .appendingPathComponent(embeddingsRevision)
            .appendingPathComponent("embeddings")

        return fm.fileExists(atPath: weightsSnapshot.path)
            && fm.fileExists(atPath: tokenizerSnapshot.path)
            && directoryContainsFiles(embeddingsSnapshot)
    }

    private func prepareRuntimeWorkingDirectory() -> URL? {
        let fm = FileManager.default

        guard let configSource = bundledConfigFileURL() else { return nil }
        guard let modelsRoot = activeModelsRoot() else { return nil }

        let runtimeDir = modelCacheDirectory().appendingPathComponent("runtime")
        let configDir = runtimeDir.appendingPathComponent("config")
        let configDest = configDir.appendingPathComponent("b6369a24.yaml")
        let modelsLink = runtimeDir.appendingPathComponent("models")

        try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)

        if fm.fileExists(atPath: configDest.path) {
            try? fm.removeItem(at: configDest)
        }
        try? fm.copyItem(at: configSource, to: configDest)

        if fm.fileExists(atPath: modelsLink.path) {
            try? fm.removeItem(at: modelsLink)
        }
        try? fm.createSymbolicLink(atPath: modelsLink.path, withDestinationPath: modelsRoot.path)

        return runtimeDir
    }

    private func bundledConfigFileURL() -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let config = URL(fileURLWithPath: resourcePath).appendingPathComponent("config/b6369a24.yaml")
        return FileManager.default.fileExists(atPath: config.path) ? config : nil
    }

    private func activeModelsRoot() -> URL? {
        if hasDownloadedModelFiles() {
            return downloadedModelsDirectory()
        }
        if let bundled = bundledModelsDirectory() {
            return bundled
        }
        return nil
    }

    private func resolveRuntimeBinaryURL() -> URL? {
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: resourcePath).appendingPathComponent("pocket-tts-cli")
            if FileManager.default.fileExists(atPath: bundled.path) {
                return bundled
            }
        }

        if let bundled = Bundle.main.url(forResource: "pocket-tts-cli", withExtension: nil) {
            return bundled
        }

        let candidates = [
            "/opt/homebrew/bin/pocket-tts-cli",
            "/usr/local/bin/pocket-tts-cli",
            NSHomeDirectory() + "/.cargo/bin/pocket-tts-cli",
            NSHomeDirectory() + "/.local/bin/pocket-tts-cli"
        ]

        for path in candidates where FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        return nil
    }

    private func directoryContainsFiles(_ directory: URL) -> Bool {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return false
        }
        return !entries.isEmpty
    }
}
