//
//  DownloadContext.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

// MARK: - 下载上下文
final class DownloadContext {
    
    let key: ResourceKey
    
    /// 资源缓存地址
    let cacheFileURL: URL
    
    var subscribers: [DownloadSubscriber]
    
    var effectivePriority: RequestPriority
    
    let creationTime: Date
    
    var startDownloadTime: Date?
    
    /// 当前资源任务已消耗的失败重试次数，所有订阅者共享。
    var failRetryCount: Int = 0
    
    // MARK: - lock from
    private var operation: DownloadOperation?

    private var resumeData: Data?
    
    private var _state: TransferState = .waiting
    
    var progress: Float?
    
    private var _mimeType: String?
    
    private var _fileSize: Int64?
    
    // MARK: - lock end
    private let stateLock = NSLock()
    
    var state: TransferState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }
    
    var mimeType: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _mimeType
    }
    
    var fileSize: Int64? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _fileSize
    }
    
    init(request: ResourceRequest, subscriber: DownloadResultSubscriber, priority: RequestPriority) {
        self.key = request.key
        self.cacheFileURL = CacheStore.default.cacheFileURL(for: request.key)
        self.subscribers = [.init(request: request, resultSubscriber: subscriber)]
        self.effectivePriority = priority
        creationTime = .init()
    }

    func updateState(_ state: TransferState) {
        stateLock.lock()
        _state = state
        stateLock.unlock()
    }

    func updateDownloadMetadata(mimeType: String?, fileSize: Int64?) {
        stateLock.lock()
        if _mimeType == nil {
            _mimeType = mimeType
        }
        if let fileSize {
            _fileSize = fileSize
        }
        stateLock.unlock()
    }

    func cancel() {
        let operation: DownloadOperation?

        stateLock.lock()
        _state = .cancelled
        operation = self.operation
        stateLock.unlock()

        operation?.cancel()
    }

    func cancelPreservingResumeData(completion: @escaping (Bool) -> Void) {
        let operation: DownloadOperation?
        stateLock.lock()
        operation = self.operation
        stateLock.unlock()
        if let operation {
            operation.cancel { [weak self] resumeData in
                guard let self else { return }
                self.stateLock.lock()
                self.resumeData = resumeData
                self.stateLock.unlock()
                completion(resumeData != nil)
            }
        } else {
            DispatchQueue.global().async {
                completion(false)
            }
        }
    }
}

extension DownloadContext: DownloadOperationDelegate {

    func downloadOperationResumeData(_ operation: DownloadOperation) -> Data? {
        stateLock.lock()
        defer { stateLock.unlock() }
        defer { resumeData = nil }
        return resumeData
    }

    func downloadOperationDidAttach(_ operation: DownloadOperation) {
        stateLock.lock()
        self.operation = operation
        stateLock.unlock()
    }

    func downloadOperation(_ operation: DownloadOperation, didFinishDownloadingAt temporaryURL: URL, response: URLResponse?) -> Result<ResourceDownloadResult, ResourceTransferError> {
        guard let response = response as? HTTPURLResponse else {
            return .failure(.invalidResponse)
        }
        guard (200 ... 299).contains(response.statusCode) else {
            return .failure(.unacceptableStatusCode(response.statusCode))
        }

        let fileSize = try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
        updateDownloadMetadata(mimeType: response.mimeType, fileSize: fileSize.map(Int64.init))

        do {
            let fileManager = FileManager.default
            try fileManager.createDirectory(
                at: cacheFileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: cacheFileURL.path) {
                try fileManager.removeItem(at: cacheFileURL)
            }
            try fileManager.moveItem(at: temporaryURL, to: cacheFileURL)
            return .success(
                .init(localURL: cacheFileURL, fileSize: fileSize.map(Int64.init), mimeType: mimeType)
            )
        } catch {
            return .failure(.underlying(error))
        }
    }

    func downloadOperationDidDetach(_ operation: DownloadOperation) {
        stateLock.lock()
        guard self.operation === operation else {
            stateLock.unlock()
            return
        }
        self.operation = nil
        stateLock.unlock()
    }
}

class DownloadSubscriber {
    
    let request: ResourceRequest
    
    let resultSubscriber: DownloadResultSubscriber
    
    init(request: ResourceRequest, resultSubscriber: DownloadResultSubscriber) {
        self.request = request
        self.resultSubscriber = resultSubscriber
    }
}
