import Foundation

public enum RoomCleanError: Error, LocalizedError, Equatable {
    case noRoomsSelected
    case unknownRooms([Int])

    public var errorDescription: String? {
        switch self {
        case .noRoomsSelected: return "Pick at least one room."
        case .unknownRooms(let ids):
            return "Rooms \(ids.map(String.init).joined(separator: ", ")) aren't on the robot's current map. Refresh the map and try again."
        }
    }
}

extension NarwalConnection {
    // MARK: Queries

    public func deviceInfo() async throws -> DeviceInfo? {
        DeviceInfo(response: try await send(Topic.getDeviceInfo).message)
    }

    /// Polled status; the payload sits in field 2 of the response.
    public func baseStatus() async throws -> BaseStatus? {
        let response = try await send(Topic.getBaseStatus)
        return response.message.message(2).map(BaseStatus.init)
    }

    public func fetchMap() async throws -> RobotMap {
        let response = try await perform(Topic.getMap, timeout: 15)
        do {
            return try RobotMap(response: response.message)
        } catch {
            throw NarwalError.noMap
        }
    }

    public func consumableAlerts() async throws -> ConsumableAlerts {
        ConsumableAlerts(response: try await send(Topic.getConsumableInfo, timeout: 15).message)
    }

    public func settings() async throws -> RobotSettings? {
        RobotSettings(response: try await send(Topic.getConfig).message)
    }

    /// Recent cleaning events. An empty answer means no history.
    public func cleaningHistory() async throws -> CleaningHistory {
        let response = try await send(Topic.getCleanTimeLine, timeout: 10)
        if let history = CleaningHistory(response: response.message) { return history }
        guard response.accepted else { throw NarwalError.rejected(Topic.getCleanTimeLine, response.resultCode) }
        return CleaningHistory(events: [])
    }

    /// Robot-stored schedules. Read-only, but the Z10 Ultra hasn't answered
    /// this yet, so nothing in the app calls it.
    public func cleanSchedules() async throws -> [CleanSchedule] {
        CleanSchedule.list(response: try await send(Topic.getCleanSchedules, timeout: 10).message)
    }

    public func cleanPlans() async throws -> [CleanPlan] {
        CleanPlan.list(response: try await send(Topic.getCleanPlans, timeout: 10).message)
    }

    /// Saves a routine as a robot clean plan; returns its id
    /// (SetCleanPlan.Response {1 result, 2 id}).
    public func saveCleanPlan(_ payload: [UInt8]) async throws -> Int {
        let response = try await perform(Topic.setCleanPlan, payload, timeout: 10)
        guard let id = response.message.int(2), id != 0 else { throw NarwalError.rejected(Topic.setCleanPlan, -1) }
        return id
    }

    public func deleteCleanPlan(_ id: Int) async throws {
        try await perform(Topic.deleteCleanPlan, Payloads.singleVarint(id))
    }

    /// Sends a schedule change, then reads the schedules back.
    public func changeSchedules(_ topic: String, _ payload: [UInt8]) async throws -> [CleanSchedule] {
        let response = try await send(topic, payload, timeout: 10)
        if let code = ScheduleReply.failure(response.message) { throw NarwalError.rejected(topic, code) }
        return try await cleanSchedules()
    }

    public func currentCleanTask() async throws -> CommandResponse {
        try await send(Topic.currentCleanTask)
    }

    // MARK: Task control

    public func locate() async throws { try await perform(Topic.yell) }
    public func pause() async throws { try await perform(Topic.pause) }
    public func resume() async throws { try await perform(Topic.resume) }
    /// force_end answers only after the robot physically stops (10-15 s).
    public func stopTask() async throws { try await perform(Topic.forceEnd, timeout: 20) }
    public func returnToDock() async throws { try await perform(Topic.recall) }
    public func quickClean() async throws { try await perform(Topic.easyClean) }

    public func setFanLevel(_ level: FanLevel) async throws {
        try await perform(Topic.setFanLevel, Payloads.setFanLevel(level))
    }

    public func setMopHumidity(_ level: MopHumidity) async throws {
        try await perform(Topic.setMopHumidity, Payloads.setMopHumidity(level))
    }

    // MARK: Cleaning

    /// Cleans exactly these rooms, in this order.
    ///
    /// Uses clean/start_clean against a freshly fetched map: a stale or
    /// wrong map id has been seen to abort the job and clear the map
    /// selection in the Narwal app, and clean/plan/start silently ignores
    /// the room list. Returns the map the task was built against.
    @discardableResult
    public func cleanRooms(_ rooms: [Int], settings: CleanSettings = CleanSettings(),
                           perRoom: [Int: CleanSettings] = [:]) async throws -> RobotMap {
        guard !rooms.isEmpty else { throw RoomCleanError.noRoomsSelected }
        let map = try await fetchMap()
        let known = Set(map.rooms.map(\.id))
        let unknown = rooms.filter { !known.contains($0) }
        guard unknown.isEmpty else { throw RoomCleanError.unknownRooms(unknown) }
        try await perform(Topic.startClean,
                          Payloads.startClean(mapId: map.mapId, rooms: rooms, settings: settings, perRoom: perRoom),
                          timeout: 10)
        return map
    }

    /// Whole house: every room, through the same verified path as room cleans.
    @discardableResult
    public func cleanAll(settings: CleanSettings = CleanSettings(),
                         perRoom: [Int: CleanSettings] = [:]) async throws -> RobotMap {
        let map = try await fetchMap()
        let rooms = map.rooms.map(\.id)
        guard !rooms.isEmpty else { throw NarwalError.noMap }
        try await perform(Topic.startClean,
                          Payloads.startClean(mapId: map.mapId, rooms: rooms, settings: settings, perRoom: perRoom),
                          timeout: 10)
        return map
    }

    /// Cleans drawn rectangles (world coordinates). Must start from the dock.
    @discardableResult
    public func cleanZones(_ zones: [Payloads.Zone], settings: CleanSettings = CleanSettings()) async throws -> RobotMap {
        guard !zones.isEmpty else { throw RoomCleanError.noRoomsSelected }
        let map = try await fetchMap()
        try await perform(Topic.startClean,
                          Payloads.zoneClean(mapId: map.mapId, zones: zones, settings: settings),
                          timeout: 10)
        return map
    }

    // MARK: Settings (writes)

    // Each write reads the settings back, so a silently ignored write shows
    // up. Not yet tried on a robot: the app only sends these once the owner
    // turns on Settings > Change robot settings.

    /// Sets the robot's voice volume (0-100) via config/set.
    @discardableResult
    public func setVoiceVolume(_ percent: Int) async throws -> RobotSettings? {
        try await perform(Topic.setConfig, Payloads.setVoiceVolume(percent))
        return try await settings()
    }

    @discardableResult
    public func setSetting(_ key: RobotSettingKey, _ value: Int) async throws -> RobotSettings? {
        try await perform(Topic.setConfig, Payloads.setConfig(key, value))
        return try await settings()
    }

    @discardableResult
    public func setDoNotDisturb(_ dnd: RobotSettings.DoNotDisturb) async throws -> RobotSettings? {
        try await perform(Topic.setConfig, Payloads.setDoNotDisturb(dnd))
        return try await settings()
    }

    /// The robot's photo of a recognised obstacle, if it sends one locally.
    public func obstaclePhoto(_ id: Int) async throws -> Data? {
        ObstaclePhoto.imageData(try await send(Topic.getVisionImage, Payloads.obstaclePhoto(id), timeout: 15).message)
    }

    // MARK: Map edits

    /// Sets how the robot treats one carpet, then fetches the map back so the
    /// change can be checked. (The reply may carry a map too, but possibly
    /// without its pixels.)
    public func setCarpetCleanOption(_ carpetId: Int, to option: Int, on map: RobotMap) async throws -> RobotMap {
        try await perform(Topic.mapOperation,
                          Payloads.carpetCleanOption(map, carpetId: carpetId, option: option),
                          timeout: 10)
        return try await fetchMap()
    }

    /// Applies map edits in one map/operation, then fetches the map back.
    public func editMap(_ edits: [MapEdit], on map: RobotMap) async throws -> RobotMap {
        try await perform(Topic.mapOperation, Payloads.mapOperation(map, edits), timeout: 15)
        return try await fetchMap()
    }

    /// Acknowledges the robot's current warning, as the Narwal app's
    /// "issue resolved" button seems to. Untried; the payload is a guess.
    public func confirmWarning() async throws {
        try await perform(Topic.confirmWarning)
    }

    // MARK: Dock

    public func washMop() async throws { try await perform(Topic.washMop) }
    public func dryMop() async throws { try await perform(Topic.dryMop) }
    public func emptyDustbin() async throws { try await perform(Topic.dustGathering) }
    public func dryDustBag() async throws { try await perform(Topic.dryDustBag) }
    public func dryStationBag() async throws { try await perform(Topic.dryStationBag) }

    public func setAmbientLight(_ mode: AmbientLightMode) async throws {
        let response = try await send(Topic.ambientLight, Payloads.singleVarint(mode.rawValue))
        guard [0, 1, 2, 6].contains(response.resultCode) else {
            throw NarwalError.rejected(Topic.ambientLight, response.resultCode)
        }
    }
}
