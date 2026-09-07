//
//  DownloadResultImageSubscriber.swift
//  ResourceTransferKit
//
//  Created by Howard-Zjun on 2026/9/6.
//

import UIKit

class DownloadResultImageSubscriber: DownloadResultSubscriber {

    weak var imageView: UIImageView?

    init(imageView: UIImageView) {
        self.imageView = imageView
        super.init()
    }

    override func matches(_ subscriber: DownloadResultSubscriber) -> Bool {
        guard let imageView,
              let subscriber = subscriber as? DownloadResultImageSubscriber else {
            return super.matches(subscriber)
        }
        return imageView === subscriber.imageView
    }
}
