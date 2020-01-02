//
//  DataManager.swift
//  Stopwatch
//
//  Created by Alex Decker on 2017-09-26.
//  Copyright © 2017 me. All rights reserved.
//

//TODO: Use oauth to get dropbox access token for users.
// So far, I've only used an access token for my own account:
// https://blogs.dropbox.com/developers/2014/05/generate-an-access-token-for-your-own-account/
let DROPBOX_ACCESS_TOKEN = "DROPBOX_ACCESS_TOKEN"

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
            if db.userVersion < 3 {
                // migrate to v2: add column minutes
                try db.run(Table("sessions").addColumn(.minutes))
                db.userVersion = 3
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
        self.dropboxSyncDownload {
            // after syncing with Dropbox: consolidate sessions
            self.consolidateSessions()
        }
        
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
            //print("#debug\t\(totalTime)\tdevice \(device[.uuid])\t\(device[.baseHours])h")
        }
        
        // now go through the sessions
        let sessionsQuery = Table("sessions").order(Expression<Double>.startTime.asc)
        guard let squery = try? db.prepare(sessionsQuery) else {
            return totalTime
        }
        
        var sessions: [Session] = []
        
        for dbsession in squery {
            let session = Session(id: dbsession[.id], device: dbsession[.device_uuid], startTime: dbsession[.startTime], minutes: minutesFromRow(dbsession))
            sessions.append(session)
        }
        
        // filter / merge sessions
        var filteredSessions = [Session]()
        while sessions.count > 0 {
            var adjSession = sessions.removeFirst()
            if let nextSession = sessions.first, nextSession.startTime < adjSession.endTime {
                // whichever way that next session goes, if it started while this session was still running, that means this session got interrupted
                adjSession.endTime = nextSession.startTime
            }
            filteredSessions.append(adjSession)
        }
        
        for session in filteredSessions {
            totalTime += session.hours
            //print("#debug\t\(totalTime)\tsession\t\(session)")
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
    
    func logSession(startTime: Date, minutes: Double) {
        guard let db = self.openDBConnection() else {
            return
        }
        
        let sessions = Table("sessions")
        do {
            try db.run(sessions.insert(.device_uuid <- self.uuid, .startTime <- startTime, .minutes <- minutes, .hours <- 0))    // note that the time might be negative. The session duration is abs(minutes).
            // Also, if .minutes is set, .hours will be ignored.
        } catch {
            print("logSession: \(error)")
        }
        
        self.dropboxSyncUpload()
    }
    
    func consolidateSessions() {
        /*
         ~~~ pseudo code ~~~
         read all sessions into "sessions" array
         for each session, as long as there is a next session:
            if session overlaps with next session:
                mark next session as "ignore"
                if session is my device:
                    shorten session
                    mark as "writeBackIfIgnored"
                else:
                    mark as "ignore"
         for each session that is not my device:
            delete from "sessions" array
         for each session marked as "ignore" _or_ less than a week old:
            if session has "writeBackIfIgnored":
                write changed session duration back to database
         make a sum of all durations of sessions that are left over
         add that sum to my device's baseHours, in memory and in database
         delete all those sessions from database
         if there have been changes in sessions:
            write back to database
         ~~~ end code ~~~
 */
        guard let db = self.openDBConnection(),
            let _ = try? self.createDeviceInDatabaseIfNeeded(db: db, uuid: self.uuid) else {
                return
        }
        
        // 1. Read all sessions
        let sessionsQuery = Table("sessions").order(Expression<Double>.startTime.asc)
        guard let squery = try? db.prepare(sessionsQuery) else {
            return
        }
        
        var sessions: [Session] = []
        
        for session in squery {
            sessions.append(Session(id: session[.id], device: session[.device_uuid], startTime: session[.startTime], minutes: minutesFromRow(session)))
        }
        
        var ignoredSessions: Set<Session> = .init()
        var writeBackIfIgnored: Set<Session> = .init()
        
        //print("session duration before: \(sessions.map({$0.hours}).reduce(0,+))")
        
        // 2. Check for overlapping sessions
        for (i, session) in sessions.enumerated() {
            guard i < sessions.count - 1 else {
                continue
            }
            let nextSession = sessions[i+1]
            if nextSession.startTime < session.endTime {
                ignoredSessions.insert(nextSession)
                if session.device == self.uuid {
                    var mySession = session
                    mySession.endTime = nextSession.startTime
                    sessions[i] = mySession
                    //session.endTime = nextSession.startTime
                    writeBackIfIgnored.insert(mySession)
                } else {
                    //#delete
                    var mySession = session
                    mySession.endTime = nextSession.startTime
                    sessions[i] = mySession
                    
                    
                    
                    ignoredSessions.insert(session)
                }
            }
        }
        
        //print("session duration after: \(sessions.map({$0.hours}).reduce(0,+))")
        
        // 3. clean up: only keep sessions from this device that don't have "ignore" set and are more than 1 week old, for good measure.
        
        while let index = sessions.index(where: { $0.device != self.uuid }) {
            sessions.remove(at: index)
        }
        while let index = sessions.index(where: { ignoredSessions.contains($0) || $0.endTime.timeIntervalSinceNow > -7*86400 }) {
            let session = sessions[index]
            if writeBackIfIgnored.contains(session) {
                // write shortened time back to database
                let updateQuery = Table("sessions").where(.id == session.id).update(.minutes <- session.minutes, .hours <- 0)
                _ = try? db.run(updateQuery)
            }
            sessions.remove(at: index)
        }
        
        //print("sessions to consolidate: \(sessions.count)")
        
        if sessions.count > 0 {
            
            // 4. sum up all of my sessions
            
            do {
                let mySessionsTotalMinutes = sessions.map({ $0.minutes }).reduce(0,+)
                
                var baseHours: Double = mySessionsTotalMinutes / 60
                if let meDevice = try db.pluck(self.thisDeviceQuery) {
                    baseHours += meDevice[.baseHours]
                }
                
                // delete all of my sessions from database
                for session in sessions {
                    let deleteQuery = Table("sessions").where(.id == session.id).delete()
                    try db.run(deleteQuery)
                }
                
                let updateQuery = Table("devices").where(.uuid == self.uuid).update(.baseHours <- baseHours)
                try db.run(updateQuery)
                
                print("Consolidated \(sessions.count) sessions!")
            } catch {
                print("consolidate db error: \(error)")
            }
        }
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
            client = DropboxClient(accessToken: DROPBOX_ACCESS_TOKEN)
            DropboxClientsManager.authorizedClient = client
        }
        
        return client
    }
    
    // jk = JSON Key
    struct jk {
        static let uuid = "uuid", baseHours = "baseHours", sessions = "sessions", startTime = "startTime", endTime = "endTime", minutes = "minutes", direction = "direction"
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
                self.dbxActiveSessions[key]?[jk.endTime] = startTime.timeIntervalSince1970
                syncSessions.append(key)
            }
        }
        
        if syncSessions.count > 0 {
            self.writeRemoteSessionsToDB()
        }
        
        syncSessions.append(self.uuid)
        let newSession = [jk.startTime: startTime.timeIntervalSince1970, jk.direction: direction] as [String : Any]
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
    
    func pauseRemoteSession() {
        let now = Date()
        if let (device, sessionToStop) = self.dbxRemoteSession {
            var session = sessionToStop
            session[jk.endTime] = now.timeIntervalSince1970
            if let jsonData = try? JSONSerialization.data(withJSONObject: session, options: []) {
                self.dropboxClient.files.upload(path: "/\(dbxActiveSessionFileName(for: device))", mode: .overwrite, input: jsonData).response { response, error in
                    print("End session remotely: \(String(describing: response)), \(String(describing: error))")
                }
                self.dbxActiveSessions[device] = session
            }
            //self.remoteSessionDidStop(device: device)
            self.writeRemoteSessionsToDB()
        }
        
        // just to make sure the session is stopped after consolidation, even if something else goes wrong
        self.logSession(startTime: now, minutes: 0)
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
                    let remoteStartTime = Date(timeIntervalSince1970: startTimeStamp)
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
                activeSessions[device[.uuid]] = [jk.startTime: startTime.timeIntervalSince1970, jk.direction: direction]
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
            sessions.append(Session(id: session[.id], device: session[.device_uuid], startTime: session[.startTime], minutes: minutesFromRow(session)))
        }
        
        let myDeviceDict = [jk.uuid: uuid, jk.baseHours: baseHours, jk.sessions: sessions.map({ [jk.startTime: $0.startTime.timeIntervalSince1970, jk.minutes: $0.minutes] })] as [String : Any]
        
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
    
    private func dropboxSyncDownload(completion: (() -> ())? = nil) {
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
                
                completion?()

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
                if let remoteStartTimeStamp = session[jk.startTime] as? Double, localStartTime.timeIntervalSince1970 > remoteStartTimeStamp {
                    // if the remote session started after the local one, we're not going in here because it's not the remote one that needs to end.
                    remoteSessionShouldEnd = true
                    remoteSessionsChanged = true
                    
                    var endedSession = session
                    endedSession[jk.endTime] = localStartTime.timeIntervalSince1970
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
                        TimingController.controller.remoteStartTime = Date(timeIntervalSince1970: remoteStartTimeStamp)
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
                    /*if let fileContents = String(data: data, encoding: .utf8) {
                        print(fileContents)
                    }*/
                    
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
                                        let minutes = (endTimeStamp - startTimeStamp) / 60 * direction
                                        self.logSession(startTime: Date(timeIntervalSince1970: startTimeStamp), minutes: minutes)
                                    }
                                    TimingController.controller.stopSessionWithoutLogging(at: Date(timeIntervalSince1970: endTimeStamp))
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
                        var remoteSessions = sessionsDictArray.compactMap({ dict -> Session? in
                            guard let startTimeStamp = dict[jk.startTime], let minutes = dict[jk.minutes] else {
                                return nil
                            }
                            // we don't know the session id, and it doesn't matter here either - the database will set it automatically
                            return Session(id: -1, device: uuid, startTime: Date(timeIntervalSince1970: startTimeStamp), minutes: minutes)
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
                                
                                let minutes = minutesFromRow(localSession)
                                if minutes != remoteSession.minutes {
                                    // update in database
                                    let updateQuery = sessionsTable
                                        .filter(.id == localSession[.id])
                                        .update(.minutes <- remoteSession.minutes)
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
                                .minutes <- remoteSession.minutes,
                                .hours <- 0
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
    static var minutes: Expression<Double?> { return Expression<Double?>("minutes") }
}

struct Session {
    let id: Int
    let device: String
    let startTime: Date
    var minutes: Double
    
    var hours: Double {
        return self.minutes / 60
    }
    
    var direction: Double {
        if minutes >= 0 {
            return 1
        } else {
            return -1
        }
    }
    var endTime: Date {
        get {
            let seconds = abs(minutes) * 60
            return startTime.addingTimeInterval(seconds)
        }
        set {
            let seconds = newValue.timeIntervalSince(self.startTime)
            self.minutes = seconds/60 * self.direction
        }
    }
}

extension Session: Hashable {
    static func ==(lhs: Session, rhs: Session) -> Bool {
        return lhs.device == rhs.device && lhs.startTime == rhs.startTime
    }
    
    var hashValue: Int {
        return self.startTime.hashValue
    }
}

extension Session: CustomStringConvertible {
    var description: String {
        return "\(startTime)\t\(minutes)m\t(\(device))"
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

fileprivate func minutesFromRow(_ row: Row) -> Double {
    if let minutes = row[.minutes], minutes != 0 {
        return minutes
    } else {
        return row[.hours] * 60
    }
}
