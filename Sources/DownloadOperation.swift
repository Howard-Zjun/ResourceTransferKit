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

    private weak var downloader: ImageResourceDownloader?

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
        downloader: ImageResourceDownloader
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
        let task = session.downloadTask(with: urlRequest) { [weak self] tempURL, response, error in
            guard let self else { return }
            defer {
                self.clearTask()
                self.finish()
            }
            guard !isCancelled else { return }

            if let error {
                let transferError: ResourceTransferError
                if let urlError = error as? URLError {
                    transferError = .network(urlError)
                } else {
                    transferError = .underlying(error)
                }
                downloader?.errorEnd(key: context.key, error: transferError)
                return
            }
            guard let response = response as? HTTPURLResponse else {
                downloader?.errorEnd(key: context.key, error: .invalidResponse)
                return
            }
            guard (200 ... 299).contains(response.statusCode) else {
                downloader?.errorEnd(key: context.key, error: .unacceptableStatusCode(response.statusCode))
                return
            }
            guard let tempURL else {
                downloader?.errorEnd(key: context.key, error: .missingDownloadedFile)
                return
            }
            
            do {
                let localURL = try self.persistDownloadedFile(from: tempURL)
                downloader?.successEnd(key: context.key, localURL: localURL)
            } catch {
                downloader?.errorEnd(key: context.key, error: .underlying(error))
            }
        }
        resume(task: task)
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

    private func resume(task: URLSessionDownloadTask) {
        stateLock.lock()
        guard !isCancelled, !_isFinished else {
            stateLock.unlock()
            task.cancel()
            return
        }
        self.task = task
        task.resume()
        stateLock.unlock()
    }

    private func clearTask() {
        stateLock.lock()
        task = nil
        stateLock.unlock()
    }

    private func cancelTask() {
        stateLock.lock()
        let task = task
        self.task = nil
        stateLock.unlock()
        task?.cancel()
    }
    
    private func persistDownloadedFile(from temporaryURL: URL) throws -> URL {
        let destinationURL = context.destinationURL
        let fileManager = FileManager.default

        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: temporaryURL, to: destinationURL)
        return destinationURL
    }
}
