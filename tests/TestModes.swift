// Native test launch modes. Compiled only into TEST_BUILD=1 apps with
// -D TOKEN_MONITOR_TESTS; release builds contain none of this code.
#if TOKEN_MONITOR_TESTS
import Cocoa

let testModeMarker = "TOKEN_MONITOR_TEST_MODE: native checks compiled in"

func launchDiagnostic(_ phase:String,_ item:NSStatusItem?=nil) {
    guard CommandLine.arguments.contains("--diagnostics") else {return}
    var fields:[String:Any] = ["phase":phase,"pid":ProcessInfo.processInfo.processIdentifier,"time":Date().description,"policy":NSApp.activationPolicy().rawValue]
    if let item=item {
        fields["visible"]=item.isVisible;fields["length"]=item.length
        fields["button"]=item.button != nil;fields["image"]=item.button?.image != nil
        fields["frame"]=item.button?.window.map {NSStringFromRect($0.frame)} ?? "none"
        fields["screen"]=item.button?.window?.screen.map {NSStringFromRect($0.frame)} ?? "none"
    }
    if let data=try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]),let line=String(data:data,encoding:.utf8) {
        let url=URL(fileURLWithPath:"/tmp/TokenMonitor-launch-diagnostic.jsonl")
        if !FileManager.default.fileExists(atPath:url.path) {FileManager.default.createFile(atPath:url.path,contents:nil)}
        if let file=try? FileHandle(forWritingTo:url) {file.seekToEndOfFile();file.write(Data((line+"\n").utf8));try? file.close()}
    }
}

func runTestMode() throws -> Bool {
    if CommandLine.arguments.contains("--updater-self-test") {
        print(testModeMarker)
        precondition(Bundle.main.bundleIdentifier?.hasPrefix("local.monitor.updater-test.") == true, "Use the isolated updater fixture")
        _ = NSApplication.shared
        AppUpdates.shared.start { false }
        precondition(AppUpdates.shared.failure == nil, "Sparkle configuration must start successfully")
        precondition(!AppUpdates.shared.checks && !AppUpdates.shared.downloads)
        let updates = AppUpdates.shared
        precondition(updates.supportsGentleScheduledUpdateReminders && updates.pendingTitle == nil)
        updates.recordPending("2.0")
        precondition(updates.pendingTitle == "Token Monitor 2.0 · update available")
        updates.recordPending("2.0", onQuit: true); updates.recordPending("2.0")
        precondition(updates.installsOnQuit && updates.pendingTitle!.contains("on quit"))
        updates.recordPending("2.1")
        precondition(!updates.installsOnQuit && updates.pendingVersion == "2.1")
        updates.clearPending(); precondition(updates.pendingTitle == nil)
        updates.testReminderCallbacks()
        print("PASS: pending update reminders and install-on-quit state")
        print("PASS: embedded Sparkle starts with automatic checks and downloads disabled")
        return true
    }
    if CommandLine.arguments.contains("--self-test") {
        print(testModeMarker)
        precondition(compact(12_670_320_000)=="12.67B")
        precondition(compact(1_000_000_000)=="1.00B")
        precondition(compact(86_380_000)=="86.38M")
        print("PASS: billion and million token formatting")
        func q(_ used:Double?,_ reset:Double?=2000,_ observed:Double?=990,_ source:String="Claude")->Subscription {
            Subscription(id:source,source:source,label:"Test",used:used,resetsAt:reset,observed:observed,state:"current")
        }
        precondition(subscriptionWarningLevel([q(74.99)],now:1000)==0)
        precondition(subscriptionWarningLevel([q(75)],now:1000)==1)
        precondition(subscriptionWarningLevel([q(89.99)],now:1000)==1)
        precondition(subscriptionWarningLevel([q(90)],now:1000)==2)
        precondition(subscriptionWarningLevel([q(76),q(95,2000,990,"Codex")],now:1000)==2)
        precondition(subscriptionWarningLevel([q(92,2000,100)],now:1000)==2)
        precondition(subscriptionWarningLevel([q(92,1000),q(nil),q(95,nil),q(95,2000,nil)],now:1000)==0)
        precondition(subscriptionWarningLevel([q(101),q(.nan),q(90,2000,1100)],now:1000)==0)
        precondition(subscriptionWarningLevel([],now:1000)==0)
        print("PASS: subscription badge thresholds, provider priority, stale retention, expiry and unknown data")
        let fixtureHome=FileManager.default.temporaryDirectory.appendingPathComponent("TokenSources-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:fixtureHome,withIntermediateDirectories:true)
        precondition(SourceConfiguration.defaults(home:fixtureHome).usage.isEmpty)
        try FileManager.default.createDirectory(at:fixtureHome.appendingPathComponent(".codex/sessions"),withIntermediateDirectories:true)
        let detected=SourceConfiguration.defaults(home:fixtureHome)
        precondition(detected.usage == ["Codex"] && detected.subscriptions == ["Codex"] && !detected.handoff)
        try FileManager.default.removeItem(at:fixtureHome)
        let suite="TokenMonitor-settings-test-"+UUID().uuidString
        let prefs=UserDefaults(suiteName:suite)!
        let store=Store(preferences:prefs)
        precondition(store.refreshSeconds==30)
        precondition(store.configureRefresh(45));let previous=store.timer!
        precondition(store.configureRefresh(60));precondition(!previous.isValid)
        precondition(store.timer!.timeInterval==60)
        precondition(!store.configureRefresh(4) && !store.configureRefresh(3601))
        precondition(store.refreshSeconds==60)
        let custom=SourceConfiguration(usage:["Claude"],subscriptions:[],paths:["Claude":"/fixture/custom"],handoff:false)
        prefs.set(try JSONEncoder().encode(custom),forKey:"sourceConfiguration")
        let restored=Store(preferences:prefs);precondition(restored.refreshSeconds==60 && restored.sourceConfiguration == custom)
        precondition(store.quotaThresholds == QuotaThresholds())
        var badgeUpdates = 0
        store.onUpdate = { badgeUpdates += 1 }
        let activeTimer = store.timer
        precondition(store.configureQuotaThresholds(warning:60,critical:80))
        precondition(badgeUpdates == 1 && store.timer === activeTimer && !store.loading && store.process == nil)
        let limits = store.quotaThresholds
        precondition(subscriptionWarningLevel([q(59.99)],now:1000,thresholds:limits) == 0)
        precondition(subscriptionWarningLevel([q(60)],now:1000,thresholds:limits) == 1)
        precondition(subscriptionWarningLevel([q(79.99)],now:1000,thresholds:limits) == 1)
        precondition(subscriptionWarningLevel([q(80)],now:1000,thresholds:limits) == 2)
        precondition(subscriptionWarningLevel([q(65),q(85,2000,990,"Codex")],now:1000,thresholds:limits) == 2)
        precondition(subscriptionWarningLevel([q(85,2000,100)],now:1000,thresholds:limits) == 2)
        precondition(subscriptionWarningLevel([q(85,1000),q(nil),q(.nan),q(101)],now:1000,thresholds:limits) == 0)
        precondition(quotaWarnings([q(59),q(60)],now:1000,thresholds:limits).count == 1)
        for pair in [(0,80),(60,101),(80,80),(90,80)] {
            precondition(!store.configureQuotaThresholds(warning:pair.0,critical:pair.1))
        }
        precondition(store.quotaThresholds == limits && badgeUpdates == 1)
        precondition(Store(preferences:prefs).quotaThresholds == limits)
        precondition(QuotaThresholds.valid(warning:1,critical:100))
        prefs.set(95,forKey:"quotaWarningPercent");prefs.set(80,forKey:"quotaCriticalPercent")
        precondition(Store(preferences:prefs).quotaThresholds == QuotaThresholds(), "Invalid saved pairs fall back together")
        print("PASS: configurable quota thresholds, boundaries, immediate update, persistence and invalid saved pairs")
        store.timer?.invalidate();prefs.removePersistentDomain(forName:suite)
        func usageFixture(_ source:String,_ session:String,_ model:String,_ total:Int64,_ child:Int64=0)->Usage {
            Usage(source:source,session:session,agent:"same-name",project:"/fixture/project",model:model,ownTotal:total-child,subagentTotal:child,input:total-10,output:10,cacheRead:0,cacheWrite:0,total:total,latest:1000)
        }
        let usageRows=[usageFixture("Claude","one","model-a",100,20),usageFixture("Claude","two","model-a",200),usageFixture("Claude","one","model-b",50),usageFixture("Codex","one","model-a",300),usageFixture("OpenCode","three","unknown",25)]
        store.data=Snapshot(compactions:[],activeSessions:[],rows:usageRows,activeChildren:[],subscriptions:[q(95)],notices:[],sources:[],indexing:false,updated:1000)
        store.tab="Subscriptions"
        precondition(store.groups.map(\.title)==["Claude","Codex","OpenCode"])
        precondition(store.groups.map(\.total)==[350,300,25], "Group recorded rows once, including already-rolled-up children, never quota snapshots")
        precondition(store.groups.reduce(Int64(0)){$0+$1.total}==usageRows.reduce(Int64(0)){$0+$1.total})
        precondition(store.groups[0].rows.count==3 && !store.groups[0].active)
        store.tab="Agents"
        precondition(store.groups.count==4, "Same-name and cross-client sessions stay separate")
        store.tab="Subscriptions";store.data=nil
        precondition(store.groups.isEmpty, "Missing usage is not a zero subscription total")
        print("PASS: subscription usage grouping preserves totals, child rollups and session identity")
        print("PASS: refresh settings validation, timer replacement and persistence")
        return true
    }
    return false
}
#endif
