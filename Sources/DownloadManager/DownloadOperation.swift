//
//  DownloadOperation.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/3.
//

import UIKit

protocol DownloadOperationDelegate: AnyObject {

    var key: ResourceKey { get }
    var urlRequest: URLRequest { get }
    func didAttach(_ operation: DownloadOperation)
    func willLoad(_ operation: DownloadOperation)
    func loading(_ operation: DownloadOperation, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64)
    func loadEndBySuccess(_ operation: DownloadOperation, at temporaryURL: URL, response: URLResponse?)
    func loadEndByError(_ operation: DownloadOperation, error: Error?)
    func downloadOperationResumeData(_ operation: DownloadOperation) -> Data?
    func loadEndByCancel(_ operation: DownloadOperation)
}


// MARK: - 下载任务
class DownloadOperation: Operation, @unchecked Sendable {

    private weak var delegate: DownloadOperationDelegate?

    private let session: URLSession

    private weak var downloader: ResourceDownloader?

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
        self.delegate = context
        self.session = session
        self.downloader = downloader
        super.init()
        delegate?.didAttach(self)
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
        guard let delegate else {
            finish()
            return
        }
        let task: URLSessionDownloadTask
        if let resumeData = delegate.downloadOperationResumeData(self) {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: delegate.urlRequest)
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
        stateLock.unlock()
        delegate?.willLoad(self)
        task.resume()
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
        delegate?.loadEndByCancel(self)
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
        defer { stateLock.unlock() }
        guard !_isFinished else {
            return
        }
        
        willChangeValue(for: \.isExecuting)
        willChangeValue(for: \.isFinished)
        self.task = nil
        _isExecuting = false
        _isFinished = true
        didChangeValue(for: \.isFinished)
        didChangeValue(for: \.isExecuting)
    }

    private func cancelTask() {
        stateLock.lock()
        let task = task
        self.task = nil
        stateLock.unlock()
        if let task {
            _ = downloader?.removeTaskIdentifier(for: task)
        }
        delegate?.loadEndByCancel(self)
        task?.cancel()
    }
}

extension DownloadOperation {
    
    func didFinish(at temporaryURL: URL, response: URLResponse?) {
        defer {
            finish()
        }
        guard !isCancelled else { return }
        delegate?.loadEndBySuccess(self, at: temporaryURL, response: response)
    }

    func didLoad(didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        delegate?.loading(self, didWriteData: bytesWritten, totalBytesWritten: totalBytesWritten, totalBytesExpectedToWrite: totalBytesExpectedToWrite)
    }
    
    func didError(with error: Error?) {
        defer {
            finish()
        }
        guard !isCancelled else { return }
        delegate?.loadEndByError(self, error: error)
    }
    
}
