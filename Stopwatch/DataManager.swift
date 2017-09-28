//
//  DataManager.swift
//  Stopwatch
//
//  Created by Alex Decker on 2017-09-26.
//  Copyright © 2017 me. All rights reserved.
//

import Cocoa
import IOKit

import SQLite

class DataManager {
    static var manager = DataManager()
    
    struct Constants {
        static let dbFilename = "db.sqlite3"
    }
    
    private var dbConnection: Connection?
    
    private func openDBConnection() -> Connection? {
        if let dbConnection = self.dbConnection {
            return dbConnection
        } else {
            let path = NSSearchPathForDirectoriesInDomains(
                .documentDirectory, .userDomainMask, true
                ).first!
            let fileManager = FileManager.default
            
            // create directory iff it doesn’t exist
            do {
                try fileManager.createDirectory(
                    atPath: path, withIntermediateDirectories: true, attributes: nil
                )
            } catch {
                //
            }
            
            let filepath = "\(path)/\(Constants.dbFilename)"
            
            // check if file exists; if not, create it
            if !fileManager.fileExists(atPath: filepath) {
                guard let filepathInBundle = Bundle.main.resourceURL?.appendingPathComponent(Constants.dbFilename).path else {
                    return nil
                }
                do {
                    try fileManager.copyItem(atPath: filepathInBundle, toPath: filepath)
                } catch {
                    print("error: \(error)")
                    return nil
                }
            }
            
            let db = try? Connection("\(path)/\(Constants.dbFilename)")
            self.dbConnection = db
            return db
        }
    }
    
    var uuid: String
    
    init() {
        /*if let db = self.openDBConnection() {
            
        }*/
        
        // get this device's serial number
        // Get the platform expert
        let platformExpert: io_service_t = IOServiceGetMatchingService(kIOMasterPortDefault, IOServiceMatching("IOPlatformExpertDevice"));
        
        // Get the serial number as a CFString ( actually as Unmanaged<AnyObject>! )
        let serialNumberAsCFString = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0);
        
        // Release the platform expert (we're responsible)
        IOObjectRelease(platformExpert);
        
        // Take the unretained value of the unmanaged-any-object
        // (so we're not responsible for releasing it)
        // and pass it back as a String or, if it fails, an empty string
        self.uuid = serialNumberAsCFString!.takeUnretainedValue() as! String
    }
    
    private func createDeviceInDatabaseIfNeeded(db: Connection) throws {
        // check if the device exists
        let devices = Table("devices")
        let query = devices.filter(.uuid == self.uuid).count
        let count = try db.scalar(query)
        
        if count > 0 {
            // device exists!
            return
        }
        
        // else... create device
        try db.run(devices.insert(.uuid <- self.uuid, .baseHours <- 0))
    }
    
    func getTotalTime() -> Double? {
        guard let db = self.openDBConnection(),
            let _ = try? self.createDeviceInDatabaseIfNeeded(db: db) else {
                return nil
        }
        
        // time in hours
        var totalTime: Double = 0
        
        // first, add up current times of all devices
        let devices = Table("devices")
        guard let dquery = try? db.prepare(devices) else {
            return nil
        }
        
        for device in dquery {
            totalTime += device[.baseHours]
        }
        
        // now go through the sessions
        let sessionsTable = Table("sessions")
        _=sessionsTable.order(Expression<Double>.startTime.asc)
        guard let squery = try? db.prepare(sessionsTable) else {
            return totalTime
        }
        
        var sessions: [Session] = []
        
        for session in squery {
            sessions.append(Session(startTime: session[.startTime], hours: session[.hours]))
        }
        
        // filter / merge sessions
        var filteredSessions = [Session]()
        let forwardSessions = sessions.filter({$0.direction > 0})
        let backwardSessions = sessions.filter({$0.direction < 0})
        for sessions in [forwardSessions, backwardSessions] {
            for (i, session) in sessions.enumerated() {
                var adjSession = session
                if i < sessions.count - 1 {
                    let nextSession = sessions[i+1]
                    if nextSession.startTime < adjSession.endTime {
                        adjSession.endTime = nextSession.startTime
                    }
                }
                filteredSessions.append(adjSession)
            }
        }
        
        for session in filteredSessions {
            totalTime += session.hours
        }
        
        return totalTime
    }
    
    func logSession(startTime: Date, hours: Double) {
        guard let db = self.openDBConnection() else {
            return
        }
        
        let sessions = Table("sessions")
        do {
            try db.run(sessions.insert(.device_uuid <- self.uuid, .startTime <- startTime, .hours <- hours))    // note that hours might be negative. The session duration is abs(hours).
        } catch {
            print("logSession: \(error)")
        }
    }
}

extension Expression {
    static var uuid: Expression<String> { return Expression<String>("uuid") }
    static var baseHours: Expression<Double> { return Expression<Double>("baseHours") }
    
    static var device_uuid: Expression<String> { return Expression<String>("device_uuid") }
    static var startTime: Expression<Date> { return Expression<Date>("startTime") }
    static var hours: Expression<Double> { return Expression<Double>("hours") }
}

struct Session {
    var startTime: Date
    var hours: Double
    
    var direction: Double {
        if hours >= 0 {
            return 1
        } else {
            return -1
        }
    }
    var endTime: Date {
        get {
            let seconds = abs(hours) * 3600
            return startTime.addingTimeInterval(seconds)
        }
        set {
            let seconds = newValue.timeIntervalSince(self.startTime)
            self.hours = seconds/3600 * self.direction
        }
    }
    
}
