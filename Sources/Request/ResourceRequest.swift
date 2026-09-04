//
//  ResourceRequest.swift
//  ResourceTransferDemo
//
//  Created by Howard-Zjun on 2026/9/4.
//

import UIKit

protocol ResourceRequest {
 
    var key: ResourceKey { get }
    
    var url: URL { get }
    
    var savePath: URL { get }
    
    var completion: ((URL) -> Void)? { get }
    
    var errorBlock: ((ResourceTransferError) -> Void)? { get }
}
