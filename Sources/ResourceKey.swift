//
//  ResourceKey.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

public struct ResourceKey: Hashable {
    
    let url: URL

    public static func == (lhs: ResourceKey, rhs: ResourceKey) -> Bool {
        lhs.url.path == rhs.url.path
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(url.path)
    }
}
