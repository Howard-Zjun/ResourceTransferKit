//
//  TransferState.swift
//  ResourceTransferKit
//
//  Created by Howard-Zjun on 2026/9/7.
//

import Foundation

enum TransferState {
    case waiting
    case downloading(progress: Float)
    case pausing
    case paused
    case retrying(failRetryCount: Int)
    case completed
    case failed(ResourceTransferError)
    case cancelled
}
