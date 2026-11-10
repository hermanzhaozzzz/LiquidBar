import Foundation
import FanControlShared
import Testing
@testable import LiquidBar

@Test @MainActor func radiatorRecoveryLabelsRequireConfirmedHealthyAutomaticReadback() {
    for reason in ["startup", "telemetry_failed", "overheat", "sleep", "wake", "write_failed", "automatic_control_recovered"] {
        for automatic in [false, true] {
            for error: String? in [nil, "Automatic restoration was not confirmed"] {
                let status = FanControlStatus(cpuIndex: 1, chipID: 54315, driverVersion: "0.7.2",
                                              rpm: 1400, duty: 53, automatic: automatic, temperature: 60,
                                              controlledByThisConnection: false, lastReason: reason, error: error)
                #expect((AppModel.radiatorControlReason(for: status) != nil) == (automatic && error == nil))
            }
        }
    }
    #expect(AppModel.radiatorControlReason(for: nil) == nil)
}

@Test func radiatorConfirmationIsBackwardCompatibleAndDoesNotAuthorizePump() throws {
    let old = Data(#"{"cpuIndex":1,"pumpIndex":5,"confirmed":false}"#.utf8)
    var mapping = try JSONDecoder().decode(MotherboardMappingSettings.self, from: old)
    #expect(mapping.confirmedIndex(for: .cpu) == nil)
    #expect(mapping.confirmedIndex(for: .pump) == nil)
    mapping.confirmedCPUIndex = 1
    #expect(mapping.confirmedIndex(for: .cpu) == 1)
    #expect(mapping.confirmedIndex(for: .pump) == nil)
    mapping.cpuIndex = 4
    #expect(mapping.confirmedIndex(for: .cpu) == nil)
    mapping.cpuIndex = 5
    mapping.confirmedCPUIndex = 5
    #expect(mapping.confirmedIndex(for: .cpu) == nil)
    mapping.cpuIndex = 1
    mapping.confirmed = true
    #expect(mapping.confirmedIndex(for: .cpu) == 1)
    #expect(mapping.confirmedIndex(for: .pump) == 5)
    mapping.cpuIndex = 7
    #expect(mapping.confirmedIndex(for: .cpu) == nil)
}

private func radiatorHelper(_ directory: URL, behavior: String = "normal") throws -> MotherboardService {
    let helper = directory.appendingPathComponent("board.py")
    try """
    import json,pathlib,sys
    root=pathlib.Path(__file__).parent
    behavior=sys.argv[1]
    fans=[dict(index=i,name='Header '+str(i),rpm=1400 if i==1 else 3300,
               duty=53 if i==1 else 100,automatic=True,rawDuty=135 if i==1 else 255)
          for i in (1,4,5)]
    for line in sys.stdin:
        req=json.loads(line)
        with (root/'requests').open('a') as f: f.write(json.dumps(req)+'\\n')
        data={'id':req['id']}
        if req['action']=='set':
            if behavior=='denied': data['error']='injected authorization denied'
            elif behavior!='mismatch':
                fan=next(f for f in fans if f['index']==req['index'])
                fan.update(duty=req['percent'],automatic=False,rpm=req['percent']*25)
        elif req['action']=='restore':
            fan=next(f for f in fans if f['index']==req['index'])
            fan.update(duty=53,automatic=True,rpm=1400)
        elif req['action']=='restoreAll':
            for fan in fans: fan['automatic']=True
        data['snapshot']={'driverVersion':'0.7.2','chipID':54315,'fans':fans}
        print(json.dumps(data),flush=True)
    """.write(to: helper, atomically: true, encoding: .utf8)
    return MotherboardService(helperExecutable: URL(fileURLWithPath: "/usr/bin/python3"),
                              helperArguments: [helper.path, behavior], requestTimeout: 3)
}

private func radiatorRequests(_ directory: URL) throws -> [[String: Any]] {
    let path = directory.appendingPathComponent("requests")
    guard FileManager.default.fileExists(atPath: path.path) else { return [] }
    return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map {
        try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
    }
}

@Test @MainActor func radiatorMonitoringNeverTakesOverAndWritesOnlyConfirmedCPU() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = try radiatorHelper(directory)
    let settings = SettingsStore(baseDirectory: directory)
    settings.value.temporaryMotherboardControl = true
    settings.value.motherboardMapping = MotherboardMappingSettings(cpuIndex: 1, pumpIndex: 5)
    let model = AppModel(settingsStore: settings, historyStore: HistoryStore(baseDirectory: directory),
                         motherboard: service, fanServiceInstalled: { false })
    await model.prepareRadiatorControl()
    #expect(try radiatorRequests(directory).isEmpty)
    settings.value.motherboardMapping?.confirmedCPUIndex = 1
    await model.prepareRadiatorControl()
    #expect(model.radiatorFan?.automatic == true)
    #expect(model.motherboardCPUTarget == 53)
    #expect(try radiatorRequests(directory).map { $0["action"] as! String } == ["initialize"])

    for invalid in [29.0, 101, Double.nan] {
        model.motherboardCPUTarget = invalid
        await model.applyMotherboard(.cpu)
    }
    model.motherboardPumpTarget = 80
    await model.applyMotherboard(.pump)
    #expect(try radiatorRequests(directory).count == 1)

    for valid in [30.0, 100] {
        model.motherboardCPUTarget = valid
        await model.applyMotherboard(.cpu)
        #expect(model.motherboardError == nil)
        #expect(model.radiatorFan?.duty == Int(valid))
        #expect(model.radiatorFan?.automatic == false)
    }
    // A read must not move a target being edited in the panel.
    model.motherboardCPUTarget = 42
    await model.prepareRadiatorControl()
    #expect(model.motherboardCPUTarget == 42)
    await model.restoreRadiatorAutomatic()
    #expect(model.radiatorFan?.automatic == true)
    #expect(model.motherboardCPUTarget == 53)
    let writes = try radiatorRequests(directory).filter { ["set", "restore"].contains($0["action"] as? String ?? "") }
    #expect(writes.count == 3)
    #expect(writes.allSatisfy { $0["index"] as? Int == 1 })
    #expect(writes.filter { $0["action"] as? String == "set" }.allSatisfy { $0["role"] as? String == "cpu" })
    settings.value.motherboardMapping?.cpuIndex = 4
    await model.applyMotherboard(.cpu)
    #expect(try radiatorRequests(directory).filter { $0["action"] as? String == "set" }.count == 2)
    try await service.shutdown()
}

@Test @MainActor func radiatorDeniedAndUnconfirmedWritesRemainVisible() async throws {
    for behavior in ["denied", "mismatch"] {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = try radiatorHelper(directory, behavior: behavior)
        let settings = SettingsStore(baseDirectory: directory)
        settings.value.temporaryMotherboardControl = true
        settings.value.motherboardMapping = MotherboardMappingSettings(cpuIndex: 1, pumpIndex: 5, confirmedCPUIndex: 1)
        let model = AppModel(settingsStore: settings, historyStore: HistoryStore(baseDirectory: directory),
                             motherboard: service, fanServiceInstalled: { false })
        await model.prepareRadiatorControl()
        model.motherboardCPUTarget = 30
        await model.applyMotherboard(.cpu)
        #expect(model.motherboardError != nil)
        #expect(model.radiatorFan?.automatic != false)
        if behavior == "denied" {
            #expect(model.radiatorFan == nil)
            #expect(!model.canControlRadiator)
        }
        try await service.shutdown()
    }
}
