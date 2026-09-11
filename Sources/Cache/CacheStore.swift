//
//  CacheStore.swift
//  ResourceTransferKit
//
//  Created by Howard-Zjun on 2026/9/7.
//

import CryptoKit
import Foundation

public final class CacheStore: NSObject {

    private let fileManager: FileManager
    
    private let lock: NSLock = .init()
    
    public static let `default`: CacheStore = .init()
    
    private let cacheDirectory: URL
    
    var metadataFileURL: URL {
        cacheDirectory
            .appendingPathComponent("metadata")
            .appendingPathExtension("json")
    }
    
    private var cacheMetaDatas: [CacheMetadata] = []
    
    private let diskCostLimit: Int64
    
    private let diskCostTarget: Int64
    
    private let maximumAge: TimeInterval

    private override init() {
        fileManager = .default
        cacheDirectory = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("ResourceTransferKit/Cache", isDirectory: true)
        diskCostLimit = 300 * 1024 * 1024
        diskCostTarget = diskCostLimit * 4 / 5
        maximumAge = 7 * 24 * 60 * 60
        super.init()

        if let data = try? Data(contentsOf: metadataFileURL) {
            cacheMetaDatas = (try? JSONDecoder().decode([CacheMetadata].self, from: data)) ?? []
        }
        removeUnindexedFiles()
    }

    // MARK: - Unit Test
    #if DEBUG
    /// 仅供测试注入隔离目录和缓存策略，Release 环境只允许使用 CacheStore.default。
    init(
        fileManager: FileManager = .default,
        cacheDirectory: URL? = nil,
        diskCostLimit: Int64 = 300 * 1024 * 1024,
        maximumAge: TimeInterval = 7 * 24 * 60 * 60
    ) {
        self.fileManager = fileManager
        self.cacheDirectory = cacheDirectory ?? fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        .appendingPathComponent("ResourceTransferKit/Cache", isDirectory: true)
        self.diskCostLimit = max(0, diskCostLimit)
        self.diskCostTarget = max(0, diskCostLimit * 4 / 5)
        self.maximumAge = max(0, maximumAge)
        super.init()
        
        if let data = try? Data(contentsOf: metadataFileURL) {
            cacheMetaDatas = (try? JSONDecoder().decode([CacheMetadata].self, from: data)) ?? []
        }
        removeUnindexedFiles()
    }
    #endif
}

extension CacheStore {

    func cacheFileURL(for key: ResourceKey) -> URL {
        cacheDirectory.appendingPathComponent(key.cacheIdentifier)
    }

    func load(request: ResourceRequest) -> CacheMetadata? {
        lock.lock()
        defer { lock.unlock() }

        guard let index = cacheMetaDatas.firstIndex(
            where: { $0.resourceKey == request.key }
        ) else {
            return nil
        }

        let metadata = cacheMetaDatas[index]
        let localURL = cacheFileURL(for: metadata.resourceKey)
        guard fileManager.fileExists(atPath: localURL.path) else {
            cacheMetaDatas.removeAll { $0.resourceKey == request.key }
            try? saveMetadata()
            return nil
        }

        guard Date().timeIntervalSince(metadata.lastAccessDate) <= maximumAge else {
            try? fileManager.removeItem(at: localURL)
            cacheMetaDatas.removeAll { $0.resourceKey == request.key }
            try? saveMetadata()
            return nil
        }

        cacheMetaDatas[index].lastAccessDate = .init()
        try? saveMetadata()
        return cacheMetaDatas[index]
    }
}

extension CacheStore {

    func save(
        key: ResourceKey,
        downloadResult: ResourceDownloadResult,
        response: HTTPURLResponse
    ) throws -> ResourceDownloadResult {
        lock.lock()
        defer { lock.unlock() }

        let destinationURL = cacheFileURL(for: key)
        guard CacheMetadata.isStorable(response: response) else {
            return downloadResult
        }
        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        if downloadResult.localURL.standardizedFileURL != destinationURL.standardizedFileURL {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: downloadResult.localURL, to: destinationURL)
        }

        let fileSize = fileSize(at: destinationURL)
        let metadata = CacheMetadata(
            resourceKey: key,
            mimeType: downloadResult.mimeType,
            fileSize: fileSize,
            lastAccessDate: .init(),
            response: response
        )
        cacheMetaDatas.removeAll { $0.resourceKey == key }
        cacheMetaDatas.append(metadata)
        try? saveMetadata()
        let cachedResult = ResourceDownloadResult(
            localURL: destinationURL,
            fileSize: fileSize,
            mimeType: downloadResult.mimeType
        )
        removeExpiredFilesAndTrimToLimit(excluding: key)

        return cachedResult
    }

    #if DEBUG
    /// 仅供不具备 HTTP 响应的缓存单元测试构造测试数据。
    func save(
        key: ResourceKey,
        downloadResult: ResourceDownloadResult
    ) throws -> ResourceDownloadResult {
        lock.lock()
        defer { lock.unlock() }

        let destinationURL = cacheFileURL(for: key)
        try fileManager.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )

        if downloadResult.localURL.standardizedFileURL != destinationURL.standardizedFileURL {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: downloadResult.localURL, to: destinationURL)
        }

        let fileSize = fileSize(at: destinationURL)
        let metadata = CacheMetadata(
            resourceKey: key,
            mimeType: downloadResult.mimeType,
            fileSize: fileSize,
            lastAccessDate: .init()
        )
        cacheMetaDatas.removeAll { $0.resourceKey == key }
        cacheMetaDatas.append(metadata)
        try? saveMetadata()
        let cachedResult = ResourceDownloadResult(
            localURL: destinationURL,
            fileSize: fileSize,
            mimeType: downloadResult.mimeType
        )
        removeExpiredFilesAndTrimToLimit(excluding: key)

        return cachedResult
    }
    #endif

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }

        cacheMetaDatas.removeAll()
        try? fileManager.removeItem(at: cacheDirectory)
    }
}

private extension CacheStore {

    func saveMetadata() throws {
        let data = try JSONEncoder().encode(cacheMetaDatas)
        try data.write(to: metadataFileURL, options: .atomic)
    }

    /// 清理无索引或过期资源，并在超过磁盘上限时按 LRU 回收；当前保存的资源不会被移除。
    func removeExpiredFilesAndTrimToLimit(excluding protectedKey: ResourceKey) {
        removeUnindexedFiles()

        let now = Date()
        cacheMetaDatas.removeAll { metadata in
            let localURL = cacheFileURL(for: metadata.resourceKey)
            guard fileManager.fileExists(atPath: localURL.path) else {
                return true
            }
            guard metadata.resourceKey != protectedKey,
                  now.timeIntervalSince(metadata.lastAccessDate) > maximumAge else {
                return false
            }
            try? fileManager.removeItem(at: localURL)
            return true
        }

        var totalSize = cacheMetaDatas.reduce(Int64(0)) {
            $0 + ($1.fileSize ?? 0)
        }
        if totalSize > diskCostLimit {
            let evictionCandidates = cacheMetaDatas.sorted {
                $0.lastAccessDate < $1.lastAccessDate
            }
            for metadata in evictionCandidates
            where totalSize > diskCostTarget && metadata.resourceKey != protectedKey {
                try? fileManager.removeItem(
                    at: cacheFileURL(for: metadata.resourceKey)
                )
                cacheMetaDatas.removeAll { $0.resourceKey == metadata.resourceKey }
                totalSize -= metadata.fileSize ?? 0
            }
        }

        try? saveMetadata()
    }

    /// 删除缓存目录中没有对应元数据记录的普通文件，用于恢复中断或不缓存下载遗留的文件。
    func removeUnindexedFiles() {
        let indexedFileURLs = Set(
            cacheMetaDatas.map {
                cacheFileURL(for: $0.resourceKey).standardizedFileURL
            }
        )
        if let enumerator = fileManager.enumerator(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                let standardizedFileURL = fileURL.standardizedFileURL
                guard standardizedFileURL != metadataFileURL.standardizedFileURL,
                      !indexedFileURLs.contains(standardizedFileURL),
                      (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
                    continue
                }
                try? fileManager.removeItem(at: fileURL)
            }
        }
    }

    func fileSize(at localURL: URL) -> Int64? {
        guard let size = try? fileManager.attributesOfItem(atPath: localURL.path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }
}

private extension ResourceKey {

    var cacheIdentifier: String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
