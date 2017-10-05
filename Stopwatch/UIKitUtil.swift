//
//  UIKitUtil.swift
//  TwoWayStopwatch
//
//  Created by Alex Decker on 2017-10-04.
//  Copyright © 2017 me. All rights reserved.
//

import Foundation

extension String {
    func matchingStrings(regex: String, options: NSRegularExpression.Options = []) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: regex, options: options) else { return [] }
        let nsString = self as NSString
        let results  = regex.matches(in: self, options: [], range: NSMakeRange(0, nsString.length))
        return results.map { result in
            (0..<result.numberOfRanges).map { result.range(at: $0).location != NSNotFound
                ? nsString.substring(with: result.range(at: $0))
                : ""
            }
        }
    }
}
