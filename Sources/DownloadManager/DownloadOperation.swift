//
//  DownloadOperation.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/3.
//

import UIKit

// MARK: - 下载任务
class DownloadOperation: Operation, @unchecked Sendable {

    private var context: DownloadContext

    private let session: URLSession

    private weak var downloader: ResourceDownloader?

    /// 统一保护 Operation 状态与 URLSession task，避免回调线程和取消线程并发读写。
    private let stateLock = NSRecursiveLock()

    private var task: URLSessionDownloadTask?
    
    private var _isExecuting = false

    private var _isFinished = false
    
    override var isAsynchronous: Bool {
        true
    }
    
    override var isExecuting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isExecuting
    }
    
    override var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isFinished
    }
    
    init(
        context: DownloadContext,
        session: URLSession,
        downloader: ResourceDownloader
    ) {
        self.context = context
        self.session = session
        self.downloader = downloader
        super.init()
        context.operation = self
    }
    
    override func start() {
        if isCancelled {
            finish()
            return
        }
        
        stateLock.lock()
        guard !_isFinished else {
            stateLock.unlock()
            return
        }
        willChangeValue(for: \.isExecuting)
        _isExecuting = true
        didChangeValue(for: \.isExecuting)
        stateLock.unlock()
        
        main()
    }
    
    override func main() {
        let urlRequest = URLRequest(url: context.key.url)
        let task = session.downloadTask(with: urlRequest)
        resume(task: task)
    }

    private func resume(task: URLSessionDownloadTask) {
        stateLock.lock()
        guard !isCancelled, !_isFinished else {
            stateLock.unlock()
            task.cancel()
            return
        }
        self.task = task
        downloader?.register(self, for: task)
        task.resume()
        stateLock.unlock()
    }
    
    override func cancel() {
        super.cancel()
        // MARK: - 这里看之后能不能升级，如果已经下载有数据，能否将数据暂存用于下次使用
        cancelTask()
        finish()
    }
    
    private func finish() {
        stateLock.lock()
        guard !_isFinished else {
            stateLock.unlock()
            return
        }

        willChangeValue(for: \.isExecuting)
        willChangeValue(for: \.isFinished)
        
        _isExecuting = false
        _isFinished = true
        
        didChangeValue(for: \.isExecuting)
        didChangeValue(for: \.isFinished)
        stateLock.unlock()
    }
    
    private func clearTask() {
        stateLock.lock()
        let task = task
        self.task = nil
        stateLock.unlock()
        if let task {
            _ = downloader?.removeTaskIdentifier(for: task)
        }
    }

    private func cancelTask() {
        stateLock.lock()
        let task = task
        self.task = nil
        stateLock.unlock()
        if let task {
            _ = downloader?.removeTaskIdentifier(for: task)
        }
        task?.cancel()
    }
}

extension DownloadOperation {
    
    func didFinishDownloading(at temporaryURL: URL, response: URLResponse?) {
        defer {
            clearTask()
            finish()
        }
        guard !isCancelled else { return }
        guard let response = response as? HTTPURLResponse else {
            downloader?.downloadFail(key: context.key, error: .invalidResponse)
            return
        }
        guard (200 ... 299).contains(response.statusCode) else {
            downloader?.downloadFail(key: context.key, error: .unacceptableStatusCode(response.statusCode))
            return
        }

        if context.mimeType == nil {
            context.mimeType = response.mimeType
        }
        if let fileSize = try? temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            context.fileSize = Int64(fileSize)
        }

        do {
            let localURL = try persistDownloadedFile(from: temporaryURL)
            downloader?.downloadSuccess(key: context.key, result: .init(localURL: localURL, fileSize: context.fileSize, mimeType: context.mimeType))
        } catch {
            downloader?.downloadFail(key: context.key, error: .underlying(error))
        }
    }

    func didComplete(with error: Error?) {
        guard let error else { return }
        defer {
            clearTask()
            finish()
        }
        guard !isCancelled else { return }

        if let urlError = error as? URLError {
            downloader?.downloadFail(key: context.key, error: .network(urlError))
        } else {
            downloader?.downloadFail(key: context.key, error: .underlying(error))
        }
    }
    
    private func persistDownloadedFile(from temporaryURL: URL) throws -> URL {
        let moduleSaveURL = context.moduleSaveURL
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: moduleSaveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: moduleSaveURL.path) {
            try fileManager.removeItem(at: moduleSaveURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: moduleSaveURL)
        return moduleSaveURL
    }
}
