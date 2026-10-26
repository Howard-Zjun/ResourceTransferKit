import CryptoKit
import Foundation

/// 未完成下载的续传记录，与完整资源缓存分开保存。
internal final class ResumeDataStore {

    static let shared = ResumeDataStore()

    private let directoryURL: URL
    private let lock = NSLock()
    private var activeTransfers: [ResourceKey: UUID] = [:]

    private init() {
        directoryURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ResourceTransferKit/ResumeData", isDirectory: true)
    }

    #if DEBUG
    internal init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }
    #endif

    /// 新上下文接管资源，旧上下文的异步取消结果不再允许写入。
    func beginTransfer(for key: ResourceKey) -> UUID {
        lock.lock()
        defer { lock.unlock() }
        let identifier = UUID()
        activeTransfers[key] = identifier
        return identifier
    }

    @discardableResult
    func save(_ data: Data, for key: ResourceKey, transferID: UUID) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard activeTransfers[key] == transferID, !data.isEmpty else { return false }
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        try data.write(to: fileURL(for: key), options: .atomic)
        return true
    }

    /// 每条记录只交给一个新任务，避免失败后反复使用同一份失效数据。
    func take(for key: ResourceKey, transferID: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard activeTransfers[key] == transferID else { return nil }
        let url = fileURL(for: key)
        let data = try? Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        guard let data, !data.isEmpty else { return nil }
        return data
    }

    /// 成功后移除记录并撤销写入资格，阻止迟到的取消回调重新保存旧数据。
    func remove(for key: ResourceKey, transferID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard activeTransfers[key] == transferID else { return }
        activeTransfers.removeValue(forKey: key)
        try? FileManager.default.removeItem(at: fileURL(for: key))
    }

    private func fileURL(for key: ResourceKey) -> URL {
        let digest = SHA256.hash(data: Data(key.url.absoluteString.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(name).appendingPathExtension("resume")
    }
}
