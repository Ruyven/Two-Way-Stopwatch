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
import SwiftyDropbox

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
        
        //FIXME: I can use ListFolderLongpoll to monitor it for changes. However, I will need to store the current cursor.
        self.dropboxSyncDownload()
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
        let sessionsQuery = Table("sessions").order(Expression<Double>.startTime.asc)
        guard let squery = try? db.prepare(sessionsQuery) else {
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
        for _sessions in [forwardSessions, backwardSessions] {
            var sessions = _sessions
            while sessions.count > 0 {
                var adjSession = sessions.removeFirst()
                while let nextSession = sessions.first, nextSession.startTime < adjSession.endTime {
                    if nextSession.endTime > adjSession.endTime {
                        adjSession.endTime = nextSession.endTime
                    }
                    _=sessions.removeFirst()
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
        
        self.dropboxSyncUpload()
    }
    
    // MARK: - Dropbox Sync
    
    var myFilenameInDropbox: String {
        return "\(self.uuid).json"
    }
    
    //FIXME: sync on launch (at least download)
    
    //TODO: sync (download) regularly?
    
    private var dropboxClient: DropboxClient {
        var client: DropboxClient! = DropboxClientsManager.authorizedClient
        
        if client == nil {
            client = DropboxClient(accessToken: "DROPBOX_ACCESS_TOKEN") // insert real token here
            DropboxClientsManager.authorizedClient = client
        }
        
        return client
    }
    
    // jk = JSON Key
    struct jk {
        static let uuid = "uuid", baseHours = "baseHours", sessions = "sessions", startTime = "startTime", hours = "hours"
    }
    
    // upload: generate data for my device
    private func dropboxSyncUpload() {
        let uuid = self.uuid
        
        guard let db = self.openDBConnection() else {
            return
        }
        
        let deviceQuery = Table("devices").where(.uuid == uuid)
        guard let omeDevice = try? db.pluck(deviceQuery), let meDevice = omeDevice else {
            // this device is not in the database ~> nothing to upload!
            return
        }
        
        let baseHours = meDevice[.baseHours]
        
        
        // now get all of this device's sessions
        let sessionsQuery = Table("sessions").where(.device_uuid == uuid)
        guard let squery = try? db.prepare(sessionsQuery) else {
            return
        }
        
        var sessions: [Session] = []
        
        for session in squery {
            sessions.append(Session(startTime: session[.startTime], hours: session[.hours]))
        }
        
        let myDeviceDict = [jk.uuid: uuid, jk.baseHours: baseHours, jk.sessions: sessions.map({ [jk.startTime: $0.startTime.timeIntervalSinceReferenceDate, jk.hours: $0.hours] })] as [String : Any]
        
        guard let jsonData = try? JSONSerialization.data(withJSONObject: myDeviceDict, options: []) else {
            return      // well that didn't work
        }
        
        self.dropboxClient.files.upload(path: "/\(myFilenameInDropbox)", mode: .overwrite, input: jsonData)
            .response { response, error in
                if let response = response {
                    print(response)
                } else if let error = error {
                    print(error)
                }
            }
            .progress { progressData in
                print(progressData)
        }
    }
    
    private func dropboxSyncDownload() {
        // now download jsonData from all other devices
        var dataUpdated = false
        
        // first: get a list of all devices we have in Dropbox
        
        self.dropboxClient.files.listFolder(path: "").response { response, error in
            guard let result = response else {
                print(error)
                return
            }
            
            let files = result.entries
            
            self.dropboxSyncDownloadAll(files: files) { dataUpdated in
                if dataUpdated, let baseTime = self.getTotalTime() {
                    TimingController.controller.baseTime = baseTime
                    NotificationCenter.default.post(name: .baseTimeUpdated, object: nil, userInfo: nil)
                }
            }
            
            // files[].name is the file name
            // check files[].client_modified and files[].server_modified to test if it needs to be updated in the database
            
            //FIXME: use result.cursor and result.hasMore to keep polling, if necessary
        }
    }
    
    private func dropboxSyncDownloadAll(files: [Files.Metadata], completion: @escaping ((_ changes: Bool) -> Void)) {
        if files.count > 0 {
            var remainingFiles = files
            let file = remainingFiles.removeFirst()
            
            self.dropboxSyncDownload(file: file, completion: { (changes) in
                self.dropboxSyncDownloadAll(files: remainingFiles, completion: { (otherChanges) in
                    completion(changes || otherChanges)
                })
            })
        } else {
            completion(false) // this file had no changes because it is no file
        }
    }
    
    private func dropboxSyncDownload(file: Files.Metadata, completion: @escaping ((_ changes: Bool) -> Void)) {
        guard file.name != self.myFilenameInDropbox, let filePath = file.pathDisplay else {
            completion(false)
            return
        }
        
        //FIXME: check files[].client_modified and files[].server_modified to test if it needs to be updated in the database, otherwise just call completion(false)
        
        self.dropboxClient.files.download(path: filePath)
            .response { response, error in
                if let response = response {
                    let responseMetadata = response.0
                    print(responseMetadata)
                    let fileContents = response.1
                    print(fileContents)
                    
                    // decode the json
                    guard let json = try? JSONSerialization.jsonObject(with: fileContents, options: []) as? [String: Any],
                        let uuid = json?[jk.uuid] as? String,
                        let baseHours = json?[jk.baseHours] as? Double,
                        let sessionsDictArray = json?[jk.sessions] as? [[String: Double]] else {
                            return
                    }
                    let sessions = sessionsDictArray.flatMap({ dict -> Session? in
                        guard let startTimeStamp = dict[jk.startTime], let hours = dict[jk.hours] else {
                            return nil
                        }
                        return Session(startTime: Date(timeIntervalSinceReferenceDate: startTimeStamp), hours: hours)
                    })
                    
                    //FIXME: now sync to database for the device in question. If any data has to be replaced, call completion(true) instead.
                    
                    completion(false)
                    
                } else if let error = error {
                    print(error)
                }
            }
            .progress { progressData in
                print(progressData)
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


extension NSNotification.Name {
    static let baseTimeUpdated = NSNotification.Name(rawValue: "baseTimeUpdated")
}
