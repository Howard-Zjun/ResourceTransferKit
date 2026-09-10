//
//  DownloadOperation.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/3.
//

import UIKit

protocol DownloadOperationDelegate: AnyObject {

    var key: ResourceKey { get }
    func downloadOperationDidAttach(_ operation: DownloadOperation)
    func downloadOperationResumeData(_ operation: DownloadOperation) -> Data?
    func downloadOperation(_ operation: DownloadOperation, didFinishDownloadingAt temporaryURL: URL, response: URLResponse?) -> Result<ResourceDownloadResult, ResourceTransferError>
    func downloadOperationDidDetach(_ operation: DownloadOperation)
}


// MARK: - 下载任务
class DownloadOperation: Operation, @unchecked Sendable {

    private weak var context: DownloadOperationDelegate?

    private let session: URLSession

    private weak var downloader: ResourceDownloader?

    /// 统一保护 Operation 状态与 URLSession task，避免回调线程和取消线程并发读写。
    private let stateLock = NSRecursiveLock()

    private var task: URLSessionDownloadTask?
    
    override var isAsynchronous: Bool { true }
    
    private var _isExecuting = false
    
    override var isExecuting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isExecuting
    }
    
    private var _isFinished = false
    
    override var isFinished: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _isFinished
    }
    
    init(
        context: DownloadOperationDelegate,
        session: URLSession,
        downloader: ResourceDownloader
    ) {
        self.context = context
        self.session = session
        self.downloader = downloader
        super.init()
        context.downloadOperationDidAttach(self)
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
        guard let context else {
            finish()
            return
        }
        let task: URLSessionDownloadTask
        if let resumeData = context.downloadOperationResumeData(self) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: URLRequest(url: context.key.url))
        }
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
        cancelTask()
        finish()
    }

    func cancel(completion: @escaping (Data?) -> Void) {
        super.cancel()
        stateLock.lock()
        let task = task
        self.task = nil
        stateLock.unlock()
        if let task {
            _ = downloader?.removeTaskIdentifier(for: task)
        }
        context?.downloadOperationDidDetach(self)
        guard let task else {
            finish()
            DispatchQueue.global().async {
                completion(nil)
            }
            return
        }
        task.cancel { [self] resumeData in
            finish()
            completion(resumeData)
        }
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
        context?.downloadOperationDidDetach(self)
    }

    private func cancelTask() {
        stateLock.lock()
        let task = task
        self.task = nil
        stateLock.unlock()
        if let task {
            _ = downloader?.removeTaskIdentifier(for: task)
        }
        context?.downloadOperationDidDetach(self)
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
        guard let context else { return }
        switch context.downloadOperation(
            self,
            didFinishDownloadingAt: temporaryURL,
            response: response
        ) {
        case let .success(result):
            downloader?.downloadSuccess(key: context.key, result: result)
        case let .failure(error):
            downloader?.downloadFail(key: context.key, error: error)
        }
    }

    func didComplete(with error: Error?) {
        guard let error else { return }
        defer {
            clearTask()
            finish()
        }
        guard !isCancelled, let context else { return }

        if let urlError = error as? URLError {
            downloader?.downloadFail(key: context.key, error: .network(urlError))
        } else {
            downloader?.downloadFail(key: context.key, error: .underlying(error))
        }
    }
    
}
