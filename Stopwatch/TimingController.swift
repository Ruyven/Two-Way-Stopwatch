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
    
    var localStartTime: Date = Date()
    var localDirection: Double = 0 {
        didSet {
            self.updateIconBadge()
        }
    }
    
    var remoteStartTime: Date = Date()
    var remoteDirection: Double = 0 {
        didSet {
            self.updateIconBadge()
        }
    }
    
    init() {
        self.baseTime = DataManager.manager.getTotalTime() ?? 0
        
        DispatchQueue.main.async {
            DataManager.manager.tryContinueDBSession {
                if let (startTime, direction) = $0 {
                    self.localStartTime = startTime
                    self.localDirection = Double(direction)
                    NotificationCenter.default.post(name: .startUpdatingDisplay, object: nil, userInfo: nil)
                }
            }
        }
    }
    
    var isRunningLocally: Bool {
        return self.localDirection != 0
    }
    var isRunningRemotely: Bool {
        return self.remoteDirection != 0
    }
    
    var isRunning: Bool {
        return self.isRunningLocally || self.isRunningRemotely
    }
    var direction: Double {
        if self.isRunningLocally {
            return self.localDirection
        } else if self.isRunningRemotely {
            return self.remoteDirection
        } else {
            return 0
        }
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
        self.localStartTime = startTime
        self.localDirection = Double(direction)
        DataManager.manager.startActiveSession(startTime: startTime, direction: direction)
    }
    
    func pause() {
        if self.isRunningLocally {
            // is running locally
            DataManager.manager.logSession(startTime: self.localStartTime, hours: self.currentSessionSeconds/3600)
            DataManager.manager.stopActiveSession()
            
            self.baseTime = self.currentTime
            self.localDirection = 0
        } else if self.isRunningRemotely {
            // it's running remotely! Tell the remote session to stop!
            self.stopRemoteSession()
        }
    }
    
    func remoteSessionDidStop() {
        self.baseTime = self.currentRemoteTime
        self.remoteDirection = 0
    }
    
    func stopRemoteSession() {
        self.baseTime = self.currentRemoteTime
        self.remoteDirection = 0
        DataManager.manager.stopRemoteSession()
    }
    
    func stopSessionWithoutLogging(at endTime: Date) {
        guard self.isRunning else {
            return
        }
        
        //DataManager.manager.logSession(startTime: self.startTime, hours: endTime.timeIntervalSince(self.startTime) * self.direction)
        DataManager.manager.stopActiveSession()
        
        self.baseTime = self.baseTime + (endTime.timeIntervalSince(self.localStartTime) / 3600)
        self.localDirection = 0
        
        NotificationCenter.default.post(name: .baseTimeUpdated, object: nil, userInfo: nil)
    }
    
    func discardSession() {
        guard self.isRunning else {
            return
        }
        self.localDirection = 0
        DataManager.manager.stopActiveSession()
    }
    
    var currentSessionSeconds: Double {
        return Date().timeIntervalSince(self.localStartTime) * self.localDirection
    }
    
    var currentTime: Double {
        return self.baseTime + self.currentSessionSeconds / 3600     // hours
    }
    
    private var currentRemoteSessionSeconds: Double {
        return Date().timeIntervalSince(self.remoteStartTime) * self.remoteDirection
    }
    
    var currentRemoteTime: Double {
        return self.baseTime + self.currentRemoteSessionSeconds / 3600      // hours
    }
    
    var displayingMinutes: Int?
    
    private func displayTime(_ fromTime: Double, withSeconds: Bool = true) -> String {
        var time = fromTime
        
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
        
        // on macOS, it shows the current minutes on the icon badge
        #if os(OSX)
            if minutes != self.displayingMinutes {
                self.displayingMinutes = minutes
                self.updateIconBadge()
            }
        #endif
        
        let hmm = String(format: "\(vorzeichen)%d:%02d", hours, minutes)
        
        if withSeconds {
            return String(format: "\(hmm):%02d.%d", seconds, tenths)
        } else {
            return hmm
        }
    }
    
    var localDisplayTime: String {
        return self.displayTime(self.currentTime)
    }
    var remoteDisplayTime: String {
        return self.displayTime(self.currentRemoteTime)
    }
    
    func updateIconBadge() {
        let badgeDirection: Double
        if self.localDirection != 0 {
            badgeDirection = self.localDirection
        } else {
            badgeDirection = self.remoteDirection
        }
        #if os(OSX)
            let hmm = self.displayTime(self.isRunningRemotely ? self.currentRemoteTime : self.currentTime, withSeconds: false)
            NSApplication.shared.dockTile.badgeLabel = {
                if badgeDirection > 0 {
                    return "\(hmm) ▶"
                } else if badgeDirection < 0 {
                    return "◀ \(hmm)"
                } else {
                    return hmm
                }
            }()
        #elseif os(iOS)
            UIApplication.shared.applicationIconBadgeNumber = {
                if badgeDirection > 0 {
                    return 1
                } else if badgeDirection < 0 {
                    return 10
                } else {
                    return 0
                }
            }()
        #endif
    }
    
    
}
