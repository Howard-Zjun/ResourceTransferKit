import UIKit

public typealias SuccessBlock = @MainActor (ResourceDownloadResult) -> Void
public typealias ErrorBlock = @MainActor (ResourceTransferError) -> Void
public typealias ProgressBlock = @MainActor (Float) -> Void

public final class DownloadResultSubscriber {
    
    let identifier = UUID()

    let resource: ResourceRequest
    
    let subscriber: AnyObject?
    
    private let callbackLock = NSLock()
    private var callbackGeneration = 0
    private var isCancelled = false
    private weak var scheduler: ResourceScheduler?

    private var successBlocks: [SuccessBlock] = []
    
    private var errorBlock: [ErrorBlock] = []
    
    private var progressBlock: [ProgressBlock] = []
    
    /// 模块外统一通过 ResourceRequest.make 创建订阅。
    internal init(resource: ResourceRequest, subscriber: AnyObject?) {
        self.resource = resource
        self.subscriber = subscriber
    }

    func matches(_ subscriber: DownloadResultSubscriber) -> Bool {
        identifier == subscriber.identifier
    }
}

extension DownloadResultSubscriber {
    
    @discardableResult
    @MainActor
    public func successBlock(_ block: @escaping SuccessBlock) -> DownloadResultSubscriber {
        successBlocks.append(block)
        return self
    }
    
    @discardableResult
    @MainActor
    public func errorBlock(_ block: @escaping ErrorBlock) -> DownloadResultSubscriber {
        errorBlock.append(block)
        return self
    }
    
    @discardableResult
    @MainActor
    public func progressBlock(_ block: @escaping ProgressBlock) -> DownloadResultSubscriber {
        progressBlock.append(block)
        return self
    }
}

extension DownloadResultSubscriber {
    
    func response(result: ResourceDownloadResult) {
        let generation = currentGeneration()
        Task { @MainActor in
            guard acceptsCallbacks(generation: generation) else { return }
            successBlocks.forEach{ $0(result) }
        }
    }
    
    func response(error: ResourceTransferError) {
        let generation = currentGeneration()
        Task { @MainActor in
            guard acceptsCallbacks(generation: generation) else { return }
            errorBlock.forEach{ $0(error) }
        }
    }
    
    func response(progress: Float) {
        let generation = currentGeneration()
        Task { @MainActor in
            guard acceptsCallbacks(generation: generation) else { return }
            progressBlock.forEach{ $0(progress) }
        }
    }
}

extension DownloadResultSubscriber {
    
    @discardableResult
    public func load() -> DownloadResultSubscriber {
        ResourceScheduler.default.load(subscriber: self)
        return self
    }
    
    public func cancel() {
        callbackLock.lock()
        isCancelled = true
        callbackGeneration += 1
        let scheduler = scheduler
        callbackLock.unlock()
        scheduler?.cancel(subscriber: self)
    }

    func attach(to scheduler: ResourceScheduler) -> Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        guard !isCancelled else { return false }
        self.scheduler = scheduler
        return true
    }

    func invalidateCallbacks() {
        callbackLock.lock()
        isCancelled = true
        callbackGeneration += 1
        callbackLock.unlock()
    }

    private func currentGeneration() -> Int {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return callbackGeneration
    }

    private func acceptsCallbacks(generation: Int) -> Bool {
        callbackLock.lock()
        defer { callbackLock.unlock() }
        return !isCancelled && callbackGeneration == generation
    }
}
