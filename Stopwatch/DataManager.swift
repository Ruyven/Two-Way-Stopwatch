//
//  DataManager.swift
//  Stopwatch
//
//  Created by Alex Decker on 2017-09-26.
//  Copyright © 2017 me. All rights reserved.
//

//import IOKit

import SQLite
import SwiftyDropbox

class DataManager {
    static var manager = DataManager()
    
    struct Constants {
        static let dbFilename = "twstopwatch.sqlite3"
        static let dbxSyncInterval: Double = 10
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
            
            if let db = db {
                self.migrateDBIfNeeded(db)
            }
            
            return db
        }
    }
    
    func migrateDBIfNeeded(_ db: Connection) {
        do {
            if db.userVersion < 1 {
                // migrate to v1: add column activeSessionDirection
                try db.run(Table("devices").addColumn(.activeSessionDirection))
                db.userVersion = 1
            }
            if db.userVersion < 2 {
                // migrate to v2: add column dbxSyncCursor
                try db.run(Table("devices").addColumn(.dbxSyncCursor))
                db.userVersion = 2
            }
        } catch {
            print("Migration failed :(")
        }
    }
    
    var uuid: String
    
    private var dropboxSyncTimer: Timer?
    
    init() {
        self.uuid = UUIDManager.generateUUID()
        
        //TODO: I can use ListFolderLongpoll to monitor it for changes. However, I will need to store the current cursor.
        self.dropboxSyncDownload()
        
        DispatchQueue.main.async {
            self.readRemoteSessionsFromDB()
        }
    }
    
    private func createDeviceInDatabaseIfNeeded(db: Connection, uuid: String) throws {
        // check if the device exists
        let count = try db.scalar(Table("devices").filter(.uuid == uuid).count)
        
        if count > 0 {
            // device exists!
            return
        }
        
        // else... create device
        try db.run(Table("devices").insert(.uuid <- uuid, .baseHours <- 0))
    }
    
    private lazy var thisDeviceQuery = Table("devices").filter(.uuid == self.uuid)
    
    func getTotalTime() -> Double? {
        guard let db = self.openDBConnection(),
            let _ = try? self.createDeviceInDatabaseIfNeeded(db: db, uuid: self.uuid) else {
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
    
    func startActiveSession(startTime: Date, direction: Int) {
        do {
            guard let db = self.openDBConnection() else {
                return
            }
            try self.createDeviceInDatabaseIfNeeded(db: db, uuid: self.uuid)
            
            try db.run(thisDeviceQuery.update(.activeSessionSince <- startTime))
            try db.run(thisDeviceQuery.update(.activeSessionDirection <- direction))
            
            self.dbxStartActiveSession(startTime: startTime, direction: direction)
        } catch {
            print(error)
        }
    }
    
    func stopActiveSession() {
        do {
            guard let db = self.openDBConnection() else {
                return
            }
            
            try db.run(thisDeviceQuery.update(.activeSessionSince <- nil))
            try db.run(thisDeviceQuery.update(.activeSessionDirection <- nil))
            
            self.dbxStopActiveSession()
        } catch {
            print(error)
        }
    }
    
    func tryContinueDBSession(_ completion: @escaping (((Date, Int)?) -> Void)) {
        do {
            guard let db = self.openDBConnection(), let deviceRow = try db.pluck(thisDeviceQuery) else {
                return
            }
            if let since = deviceRow[.activeSessionSince], let direction = deviceRow[.activeSessionDirection], direction != 0 {
                completion((since, direction))
            }
        } catch {
            print(error)
        }
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
    
    private var dropboxSyncCursor: String? {
        didSet {
            guard dropboxSyncCursor != oldValue, let db = self.openDBConnection() else {
                return
            }
            do {
                let updateQuery = self.thisDeviceQuery.update(.dbxSyncCursor <- dropboxSyncCursor)
                try db.run(updateQuery)
            } catch {}
        }
    }
    
    var myFilenameInDropbox: String {
        return "\(self.uuid).json"
    }
    
    private lazy var dbxActiveSessionFile: String = {
        return self.dbxActiveSessionFileName(for: self.uuid)
    }()
    
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
        static let uuid = "uuid", baseHours = "baseHours", sessions = "sessions", startTime = "startTime", endTime = "endTime", hours = "hours", direction = "direction"
    }
    
    // MARK: active session
    
    private var dbxActiveSessions: [String: [String: Any]] = [:]
    
    private var dbxRemoteSession: (String, [String: Any])? {
        for (device, session) in self.dbxActiveSessions {
            if device != self.uuid, (session[jk.endTime] as? Double) == nil {
                return (device, session)
            }
        }
        // else
        return nil
    }
    
    private func dbxStartActiveSession(startTime: Date, direction: Int) {
        var syncSessions = [String]()
        
        // if any session is already running: pause it
        for (key, value) in self.dbxActiveSessions {
            if value[jk.endTime] as? Int == nil, value[jk.uuid] as? String != self.uuid {
                self.dbxActiveSessions[key]?[jk.endTime] = startTime.timeIntervalSinceReferenceDate
                syncSessions.append(key)
            }
        }
        
        if syncSessions.count > 0 {
            self.writeRemoteSessionsToDB()
        }
        
        syncSessions.append(self.uuid)
        let newSession = [jk.startTime: startTime.timeIntervalSinceReferenceDate, jk.direction: direction] as [String : Any]
        self.dbxActiveSessions[self.uuid] = newSession
        
        for key in syncSessions {
            guard let session = self.dbxActiveSessions[key], let jsonData = try? JSONSerialization.data(withJSONObject: session, options: []) else {
                continue
            }
            
            self.dropboxClient.files.upload(path: "/\(dbxActiveSessionFileName(for: key))", mode: .overwrite, input: jsonData).response { response, error in
                print("Started remote session: \(String(describing: response)), \(String(describing: error))")
            }
        }
    }
    
    private func dbxStopActiveSession() {
        self.dropboxClient.files.deleteV2(path: "/\(self.dbxActiveSessionFile)").response { response, error in
            print("Stopped remote session: \(String(describing: response)), \(String(describing: error))")
        }
    }
    
    func stopRemoteSession() {
        if let (device, sessionToStop) = self.dbxRemoteSession {
            var session = sessionToStop
            session[jk.endTime] = Date().timeIntervalSinceReferenceDate
            if let jsonData = try? JSONSerialization.data(withJSONObject: session, options: []) {
                self.dropboxClient.files.upload(path: "/\(dbxActiveSessionFileName(for: device))", mode: .overwrite, input: jsonData).response { response, error in
                    print("End session remotely: \(String(describing: response)), \(String(describing: error))")
                }
                self.dbxActiveSessions[device] = session
            }
            //self.remoteSessionDidStop(device: device)
            self.writeRemoteSessionsToDB()
        }
    }
    
    /*func remoteSessionDidStop(device: String) {
     
    }*/
    
    func writeRemoteSessionsToDB() {
        guard let db = self.openDBConnection() else {
            return
        }
        
        do {
            let devices = Table("devices")
            for device in try db.prepare(devices) {
                guard device[.uuid] != self.uuid else {
                    continue // another method already did that
                }
                
                var updateDeviceWith: (Date?, Int?)?
                if let session = self.dbxActiveSessions[device[.uuid]],
                    (session[jk.endTime] as? Double) == nil,
                    let startTimeStamp = session[jk.startTime] as? Double,
                    let remoteDirection = session[jk.direction] as? Int
                {
                    let remoteStartTime = Date(timeIntervalSinceReferenceDate: startTimeStamp)
                    if remoteStartTime != device[.activeSessionSince] || remoteDirection != device[.activeSessionDirection] {
                        updateDeviceWith = (remoteStartTime, remoteDirection)
                    }
                } else {
                    // there is no remote session for the device
                    if device[.activeSessionSince] != nil || device[.activeSessionDirection] != nil {
                        updateDeviceWith = (nil, nil)
                    }
                }
                
                if let (startTime, direction) = updateDeviceWith {
                    let updateQuery = devices.where(.uuid == device[.uuid]).update(.activeSessionSince <- startTime, .activeSessionDirection <- direction)
                    _ = try? db.run(updateQuery)
                }
            }
        } catch {}
    }
    
    func readRemoteSessionsFromDB() {
        guard let db = self.openDBConnection() else {
            return
        }
        
        do {
            var remoteSessionIsActive = false
            
            let devices = Table("devices")
            var activeSessions: [String: [String: Any]] = [:]
            for device in try db.prepare(devices) {
                guard device[.uuid] != self.uuid, let startTime = device[.activeSessionSince], let direction = device[.activeSessionDirection] else {
                    continue
                }
                remoteSessionIsActive = true
                activeSessions[device[.uuid]] = [jk.startTime: startTime.timeIntervalSinceReferenceDate, jk.direction: direction]
            }
            self.dbxActiveSessions = activeSessions
            if remoteSessionIsActive {
                self.checkRunningRemoteSession()
            }
        } catch {}
    }
    
    // MARK: upload: generate data for my device
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
    }
    
    private func dropboxListFolder(_ completion: @escaping ((Files.ListFolderResult?, Error?) -> Void)) {
        if let cursor = self.dropboxSyncCursor {
            self.dropboxClient.files.listFolderContinue(cursor: cursor).response { response, error in
                completion(response, error as? Error)
            }
        } else {
            self.dropboxClient.files.listFolder(path: "").response { response, error in
                completion(response, error as? Error)
            }
        }
    }
    
    private func dropboxSyncDownload() {
        // now download jsonData from all other devices
        
        // check if we have a dropbox sync cursor from last time
        if self.dropboxSyncCursor == nil, let db = self.openDBConnection(), let row = try? db.pluck(self.thisDeviceQuery), let cursor = row?[.dbxSyncCursor] {
            self.dropboxSyncCursor = cursor
        }
        
        // get a list of all devices we have in Dropbox
        self.dropboxListFolder { response, error in
            // repeat this regularly (start counting at the end of this refresh)
            defer {
                self.dropboxSyncTimer = Timer.scheduledTimer(withTimeInterval: Constants.dbxSyncInterval, repeats: false, block: { (_) in
                    self.dropboxSyncDownload()
                })
            }
            
            guard let result = response else {
                print(error as Any)
                return
            }
            
            self.dropboxSyncCursor = result.cursor
            
            let files = result.entries
            
            self.dropboxSyncDownloadAll(files: files) { dataUpdated in
                self.checkRunningRemoteSession()
                
                if dataUpdated, let baseTime = self.getTotalTime() {
                    TimingController.controller.baseTime = baseTime
                    NotificationCenter.default.post(name: .baseTimeUpdated, object: nil, userInfo: nil)
                }

            }
            
            // files[].name is the file name
            // check files[].client_modified and files[].server_modified to test if it needs to be updated in the database
            
            //TODO: use result.hasMore to keep polling, if necessary
        }
    }
    
    private func checkRunningRemoteSession() {
        // check: if any remote session is running that got started before the current device's session, it needs to be stopped remotely.
        var remoteSessionsChanged = false
        for (device, session) in self.dbxActiveSessions {
            guard device != self.uuid, (session[jk.endTime] as? Double) == nil else {
                // doesn't concern us
                continue
            }
            var remoteSessionShouldEnd = false
            if TimingController.controller.isRunningLocally {
                // the remote session needs to end!
                let localStartTime = TimingController.controller.localStartTime
                if let remoteStartTimeStamp = session[jk.startTime] as? Double, localStartTime.timeIntervalSinceReferenceDate > remoteStartTimeStamp {
                    // if the remote session started after the local one, we're not going in here because it's not the remote one that needs to end.
                    remoteSessionShouldEnd = true
                    remoteSessionsChanged = true
                    
                    var endedSession = session
                    endedSession[jk.endTime] = localStartTime.timeIntervalSinceReferenceDate
                    if let jsonData = try? JSONSerialization.data(withJSONObject: endedSession, options: []) {
                        self.dropboxClient.files.upload(path: "/\(self.dbxActiveSessionFileName(for: device))", mode: .overwrite, input: jsonData).response { response, error in
                            print("End session remotely: \(String(describing: response)), \(String(describing: error))")
                        }
                        self.dbxActiveSessions[device] = endedSession
                    }
                }
            }
            
            if !remoteSessionShouldEnd {
                // I guess we will instead display the remote session!
                if let remoteStartTimeStamp = session[jk.startTime] as? Double {
                    var rdDouble = session[jk.direction] as? Double
                    if rdDouble == nil, let rdInt = session[jk.direction] as? Int {
                        rdDouble = Double(rdInt)
                    }
                    if let remoteDirection = rdDouble {
                        TimingController.controller.remoteStartTime = Date(timeIntervalSinceReferenceDate: remoteStartTimeStamp)
                        TimingController.controller.remoteDirection = remoteDirection
                        NotificationCenter.default.post(name: .startUpdatingDisplay, object: nil)
                    }
                }
            }
        }
        if remoteSessionsChanged {
            self.writeRemoteSessionsToDB()
        }
    }
    
    private func dropboxSyncDownloadAll(files: [Files.Metadata], completion: @escaping ((_ changes: Bool) -> Void)) {
        if files.count > 0 {
            var remainingFiles = files
            let file = remainingFiles.removeFirst()
            
            //TODO: if a normal file (not _as) got deleted, delete its device entry and sessions from the local database
            
            if let device = self.dbxFileIsActiveSessionFile(file.name), file is Files.DeletedMetadata {
                // it's an active session file that got deleted!
                if self.dbxRemoteSession?.0 == device {
                    // stop displaying the active remote session
                    //self.remoteSessionDidStop()
                    TimingController.controller.remoteSessionDidStop()
                }
                self.dbxActiveSessions[device] = nil
                if device != self.uuid {
                    self.writeRemoteSessionsToDB()
                }
                self.dropboxSyncDownloadAll(files: remainingFiles, completion: completion)
                completion(false) // active sessions don't count as a change
            } else {
                self.dropboxSyncDownload(file: file, completion: { (changes) in
                    self.dropboxSyncDownloadAll(files: remainingFiles, completion: { (otherChanges) in
                        completion(changes || otherChanges)
                    })
                })
            }
        } else {
            completion(false) // this file had no changes because it is no file
        }
    }
    
    private func dropboxSyncDownload(file: Files.Metadata, completion: @escaping ((_ changes: Bool) -> Void)) {
        guard file.name != self.myFilenameInDropbox, let filePath = file.pathDisplay, let db = self.dbConnection else {
            completion(false)
            return
        }
        
        self.dropboxClient.files.download(path: filePath)
            .response { response, error in
                guard let response = response else {
                    if let error = error {
                        print(error)
                    }
                    completion(false)
                    return
                }
                
                var changes = false
                
                do {
                    let responseMetadata = response.0
                    print(responseMetadata)
                    let fileContents = response.1
                    print(fileContents)
                    
                    guard let json = try JSONSerialization.jsonObject(with: fileContents, options: []) as? [String: Any] else {
                        return
                    }
                    
                    if let deviceUUID = self.dbxFileIsActiveSessionFile(file.name) {
                        // it's an activeSession file!
                        if deviceUUID == self.uuid {
                            // we're only interested in this one if Dropbox says it should be finished by now
                            if TimingController.controller.isRunning {
                                if let endTimeStamp = json[jk.endTime] as? Double {
                                    if let startTimeStamp = json[jk.startTime] as? Double,
                                        endTimeStamp > startTimeStamp, // if the endTime is before the startTime, discard the session
                                        let direction = json[jk.direction] as? Double
                                    {
                                        let hours = (endTimeStamp - startTimeStamp) / 3600 * direction
                                        self.logSession(startTime: Date(timeIntervalSinceReferenceDate: startTimeStamp), hours: hours)
                                    }
                                    TimingController.controller.stopSessionWithoutLogging(at: Date(timeIntervalSinceReferenceDate: endTimeStamp))
                                }
                            } else {
                                // or if the local session is not running. In that case, it just needs to be deleted.
                                self.dbxStopActiveSession()
                            }
                        } else {
                            // it's a different device!
                            self.dbxActiveSessions[deviceUUID] = json
                            self.writeRemoteSessionsToDB()
                        }
                        completion(false) // changes to sessions don't count as change here
                    } else {
                        // decode the json
                        guard let uuid = json[jk.uuid] as? String,
                            let baseHours = json[jk.baseHours] as? Double,
                            let sessionsDictArray = json[jk.sessions] as? [[String: Double]] else {
                                return
                        }
                        var remoteSessions = sessionsDictArray.flatMap({ dict -> Session? in
                            guard let startTimeStamp = dict[jk.startTime], let hours = dict[jk.hours] else {
                                return nil
                            }
                            return Session(startTime: Date(timeIntervalSinceReferenceDate: startTimeStamp), hours: hours)
                        })
                        
                        // now sync to database for the device in question. If any data has to be replaced, call completion(true) instead.
                        guard uuid != self.uuid else {
                            completion(false)
                            return
                        }
                        try self.createDeviceInDatabaseIfNeeded(db: db, uuid: uuid)
                        
                        let devices = Table("devices")
                        let dquery = devices.filter(.uuid == uuid)
                        
                        if let device = try! db.pluck(dquery) {
                            if device[.baseHours] != baseHours {
                                let updateQuery = dquery.update(.baseHours <- baseHours)
                                if (try? db.run(updateQuery)) != nil {
                                    changes = true
                                }
                            }}
                        
                        // update all sessions that exist / delete all that shouldn't exist
                        let sessionsTable = Table("sessions")
                        let deviceSessions = sessionsTable.where(.device_uuid == uuid)
                        for localSession in try db.prepare(deviceSessions) {
                            if let remoteIndex = remoteSessions.index(where: {$0.startTime == localSession[.startTime]}) {
                                let remoteSession = remoteSessions[remoteIndex]
                                if localSession[.hours] != remoteSession.hours {
                                    // update in database
                                    let updateQuery = sessionsTable
                                        .filter(.id == localSession[.id])
                                        .update(.hours <- remoteSession.hours)
                                    if (try? db.run(updateQuery)) != nil {
                                        changes = true
                                    }
                                }
                                remoteSessions.remove(at: remoteIndex) // this one is done
                            } else {
                                let deleteQuery = deviceSessions
                                    .filter(.id == localSession[.id])
                                    .delete()
                                if (try? db.run(deleteQuery)) != nil {
                                    changes = true
                                }
                            }
                        }
                        
                        // if any remote sessions are left over, they have to be added to the local database
                        for remoteSession in remoteSessions {
                            let insertQuery = sessionsTable.insert(
                                .device_uuid <- uuid,
                                .startTime <- remoteSession.startTime,
                                .hours <- remoteSession.hours
                            )
                            if (try? db.run(insertQuery)) != nil {
                                changes = true
                            }
                        }
                        
                        completion(changes)
                    }
                } catch {
                    print("try error: \(error)")
                    completion(changes)
                }
            }
            .progress { progressData in
                print(progressData)
        }
        
    }
    
    func dbxFileIsActiveSessionFile(_ fileName: String) -> String? {
        if let matches = (fileName.matchingStrings(regex: "^(.+?)_as\\.json$", options: .caseInsensitive).first), matches.count > 1 {
            return matches[1]
        } else {
            return nil
        }
    }
    
    func dbxActiveSessionFileName(for deviceUUID: String) -> String {
        return "\(deviceUUID)_as.json"
    }
 }

extension Expression {
    static var id: Expression<Int> { return Expression<Int>("id") }
    static var uuid: Expression<String> { return Expression<String>("uuid") }
    static var baseHours: Expression<Double> { return Expression<Double>("baseHours") }
    static var activeSessionSince: Expression<Date?> { return Expression<Date?>("activeSessionSince")}
    static var activeSessionDirection: Expression<Int?> { return Expression<Int?>("activeSessionDirection")}
    static var dbxSyncCursor: Expression<String?> { return Expression<String?>("dbxSyncCursor") }
    
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
    static let startUpdatingDisplay = NSNotification.Name(rawValue: "startUpdatingDisplay")
}

extension Connection {
    public var userVersion: Int32 {
        get { return Int32(try! scalar("PRAGMA user_version") as! Int64)}
        set { try! run("PRAGMA user_version = \(newValue)") }
    }
}

