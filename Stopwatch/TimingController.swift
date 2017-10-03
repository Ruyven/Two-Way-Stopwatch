//
//  TimingController.swift
//  TwoWayStopwatch
//
//  Created by Alex Decker on 2017-09-28.
//  Copyright © 2017 me. All rights reserved.
//

import Foundation

#if os(OSX)
    import Cocoa
#elseif os(iOS)
    import UIKit
#endif

class TimingController {
    static var controller = TimingController()
    
    var baseTime: Double   // time in hours
    
    var startTime: Date = Date()
    var direction: Double = 0 {
        didSet {
            #if os(OSX)
                NSApplication.shared.dockTile.badgeLabel = {
                    if direction > 0 {
                        return "▶"
                    } else if direction < 0 {
                        return "◀"
                    } else {
                        return nil
                    }
                }()
            #elseif os(iOS)
                UIApplication.shared.applicationIconBadgeNumber = {
                    if direction > 0 {
                        return 1
                    } else if direction < 0 {
                        return 10
                    } else {
                        return 0
                    }
                }()
            #endif
        }
    }
    
    init() {
        self.baseTime = DataManager.manager.getTotalTime() ?? 0
        
        DispatchQueue.main.async {
            DataManager.manager.tryContinueDBSession {
                if let (startTime, direction) = $0 {
                    self.startTime = startTime
                    self.direction = Double(direction)
                    NotificationCenter.default.post(name: .startUpdatingDisplay, object: nil, userInfo: nil)
                }
            }
        }
    }
    
    var isRunning: Bool {
        return self.direction != 0
    }
    
    func startForward() {
        if self.isRunning {
            self.pause()
        }
        self.startSession(startTime: Date(), direction: 1)
    }
    
    func startBackward() {
        if self.isRunning {
            self.pause()
        }
        self.startSession(startTime: Date(), direction: -1)
    }
    
    func startSession(startTime: Date, direction: Int) {
        self.startTime = startTime
        self.direction = Double(direction)
        DataManager.manager.startActiveSession(startTime: startTime, direction: direction)
    }
    
    func pause() {
        guard self.isRunning else {
            return
        }
        
        DataManager.manager.logSession(startTime: self.startTime, hours: self.currentSessionSeconds/3600)
        DataManager.manager.stopActiveSession()
        
        self.baseTime = self.currentTime
        self.direction = 0
    }
    
    func discardSession() {
        guard self.isRunning else {
            return
        }
        self.direction = 0
        DataManager.manager.stopActiveSession()
    }
    
    var currentSessionSeconds: Double {
        return Date().timeIntervalSince(self.startTime) * self.direction
    }
    
    var currentTime: Double {
        return self.baseTime + self.currentSessionSeconds / 3600     // hours
    }
    
    var displayTime: String {
        var time = self.currentTime
        
        let vorzeichen: String
        if time >= 0 {
            vorzeichen = ""
        } else {
            vorzeichen = "-"
            time = 0 - time
        }
        
        let hours = Int(time)
        time = time - Double(hours)
        time *= 60
        let minutes = Int(time)
        time = time - Double(minutes)
        time *= 60
        let seconds = Int(time)
        time -= Double(seconds)
        let tenths = Int(time*10)
        
        return String(format: "\(vorzeichen)%d:%02d:%02d.%d", hours, minutes, seconds, tenths)
    }
    
    
}
