//
//  DownloadContext.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

// MARK: - 下载上下文
final class DownloadContext {
    
    let resource: ResourceRequest
        
    /// 资源缓存地址
    let cacheFileURL: URL
    
    var effectivePriority: RequestPriority
    
    let creationTime: Date

    var startDownloadTime: Date?
    
    /// 当前资源任务已消耗的失败重试次数，所有订阅者共享。
    private var _failRetryCount: Int = 0
    
    // MARK: - lock from
    private var operation: DownloadOperation?

    private let resumeDataStore = ResumeDataStore.shared
    private let resumeDataTransferID: UUID
    
    private var _state: TransferState = .waiting
    
    private(set) var progress: Float?
    
    private var _mimeType: String?
    
    private var _fileSize: Int64?

    private var _response: HTTPURLResponse?
    
    // MARK: - lock end
    private let stateLock = NSLock()

    private weak var scheduler: ResourceScheduler?

    var failRetryCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _failRetryCount
    }
    
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
    
    var response: HTTPURLResponse? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _response
    }
    
    init(
        resource: ResourceRequest,
        scheduler: ResourceScheduler
    ) {
        self.resource = resource
        self.resumeDataTransferID = ResumeDataStore.shared.beginTransfer(for: resource.key)
        self.scheduler = scheduler
        self.cacheFileURL = CacheStore.default.cacheFileURL(for: resource.key)
        self.effectivePriority = resource.priority
        creationTime = .init()
    }

    func cancel() {
        let operation: DownloadOperation?

        stateLock.lock()
        _state = .cancelled
        operation = self.operation
        stateLock.unlock()

        operation?.cancel()
        resumeDataStore.remove(for: key, transferID: resumeDataTransferID)
    }

    func cancelPreservingResumeData(completion: @escaping (Bool) -> Void) {
        
        let operation: DownloadOperation?
        stateLock.lock()
        _state = .pausing
        operation = self.operation
        stateLock.unlock()
        if let operation {
            let key = key
            let store = resumeDataStore
            let transferID = resumeDataTransferID
            operation.cancel { [weak self] resumeData in
                let saved: Bool
                if let resumeData {
                    saved = (try? store.save(resumeData, for: key, transferID: transferID)) ?? false
                    if !saved {
                        store.remove(for: key, transferID: transferID)
                    }
                } else {
                    store.remove(for: key, transferID: transferID)
                    saved = false
                }
                if let self {
                    self.stateLock.lock()
                    self._state = .paused
                    self.stateLock.unlock()
                }
                completion(saved)
            }
        } else {
            DispatchQueue.global().async {
                self.stateLock.lock()
                self._state = .paused
                self.stateLock.unlock()
                completion(false)
            }
        }
    }
    
    func prepareForRetry() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard case .retrying = _state else { return false }
        _state = .waiting
        progress = nil
        return true
    }

    func finishFailure(_ error: ResourceTransferError) {
        stateLock.lock()
        _state = .failed(error)
        stateLock.unlock()
        resumeDataStore.remove(for: key, transferID: resumeDataTransferID)
    }
}

extension DownloadContext: DownloadOperationDelegate {
    
    var key: ResourceKey {
        resource.key
    }

    var urlRequest: URLRequest {
        var request = URLRequest(url: key.url)
        if let metaData = CacheStore.default.load(key: key, updateAccessDate: true) {
            if let eTag = metaData.eTag {
                request.setValue(eTag, forHTTPHeaderField: "If-None-Match")
            }
            if let lastModified = metaData.lastModified {
                request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since")
            }
        }
        return request
    }
    
    func didAttach(_ operation: DownloadOperation) {
        stateLock.lock()
        self.operation = operation
        stateLock.unlock()
    }
    
    func willLoad(_ operation: DownloadOperation) {
        stateLock.lock()
        defer { stateLock.unlock() }
        
        guard self.operation === operation else { return }
        
        _state = .downloading(progress: 0)
    }
    
    func loading(_ operation: DownloadOperation, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        stateLock.lock()
        guard self.operation === operation else {
            stateLock.unlock()
            return
        }
        if startDownloadTime == nil {
            startDownloadTime = .init()
        }
        guard totalBytesExpectedToWrite > 0 else {
            stateLock.unlock()
            return
        }
        _fileSize = totalBytesExpectedToWrite
        let progress = Float(totalBytesWritten) / Float(totalBytesExpectedToWrite)
        self.progress = progress
        _state = .downloading(progress: progress)
        stateLock.unlock()
        
        scheduler?.responseProgress(context: self, progress: progress)
    }
    
    func loadEndBySuccess(_ operation: DownloadOperation, at temporaryURL: URL, response: URLResponse?) {
        stateLock.lock()
        guard self.operation === operation, !operation.isCancelled else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()
        
        guard let response = response as? HTTPURLResponse else {
            loadEndByError(operation, error: ResourceTransferError.invalidResponse)
            return
        }
        
        let result: ResourceDownloadResult
        do {
            if response.statusCode == 304 {
                guard let cachedResult = CacheStore.default.revalidate(key: key, response: response) else {
                    throw ResourceTransferError.missingDownloadedFile
                }
                result = cachedResult
            } else {
                guard (200 ... 299).contains(response.statusCode) else {
                    throw ResourceTransferError.unacceptableStatusCode(response.statusCode)
                }
                let fileManager = FileManager.default
                guard fileManager.fileExists(atPath: temporaryURL.path) else {
                    throw ResourceTransferError.missingDownloadedFile
                }
                let fileSize = try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize
                try fileManager.createDirectory(at: cacheFileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                if temporaryURL.standardizedFileURL != cacheFileURL.standardizedFileURL {
                    if fileManager.fileExists(atPath: cacheFileURL.path) {
                        try fileManager.removeItem(at: cacheFileURL)
                    }
                    try fileManager.moveItem(at: temporaryURL, to: cacheFileURL)
                }
                
                result = ResourceDownloadResult(
                    localURL: cacheFileURL,
                    fileSize: fileSize.map(Int64.init),
                    mimeType: response.mimeType
                )
                
                _ = try? CacheStore.default.save(
                    key: key,
                    downloadResult: result,
                    response: response
                )
            }
        } catch {
            let transferError = (error as? ResourceTransferError) ?? .underlying(error)
            loadEndByError(operation, error: transferError)
            return
        }
        
        stateLock.lock()
        guard self.operation === operation, !operation.isCancelled else {
            stateLock.unlock()
            return
        }
        _response = response
        _mimeType = result.mimeType
        _fileSize = result.fileSize
        progress = 1
        _state = .completed
        self.operation = nil
        stateLock.unlock()
        
        resumeDataStore.remove(for: key, transferID: resumeDataTransferID)
        scheduler?.responseBySuccess(context: self, result: result)
    }
    
    func loadEndByError(_ operation: DownloadOperation, error: (any Error)?) {
        stateLock.lock()
        guard self.operation === operation else {
            stateLock.unlock()
            return
        }
        _failRetryCount += 1
        _state = .retrying(failRetryCount: _failRetryCount)
        
        self.operation = nil
        stateLock.unlock()
        
        let transferError: ResourceTransferError
        if let error = error as? ResourceTransferError {
            transferError = error
        } else if let error, (error as NSError).domain == NSURLErrorDomain {
            transferError = .network(URLError(_nsError: error as NSError))
        } else if let error {
            transferError = .underlying(error)
        } else {
            transferError = .invalidResponse
        }
        
        scheduler?.responseByFail(context: self, error: transferError)
    }
    
    func downloadOperationResumeData(_ operation: DownloadOperation) -> Data? {
        stateLock.lock()
        guard self.operation === operation else {
            stateLock.unlock()
            return nil
        }
        stateLock.unlock()
        return resumeDataStore.take(for: key, transferID: resumeDataTransferID)
    }

    func loadEndByCancel(_ operation: DownloadOperation) {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard self.operation === operation else { return }
        self.operation = nil
    }
}
