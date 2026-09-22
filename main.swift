import Cocoa
import SwiftUI

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


let canvasColor = Color(red:0.12,green:0.14,blue:0.17)
let surface = Color(red:0.17,green:0.19,blue:0.23)
let accent = Color(red:0.64,green:0.72,blue:1)
func quotaLevel(_ used:Double)->Int { used>=90 ? 2 : used>=75 ? 1 : 0 }
func quotaColor(_ level:Int)->Color { level==2 ? Color(red:0.96,green:0.46,blue:0.45) : level==1 ? Color(red:0.94,green:0.79,blue:0.35) : accent }
func compact(_ n:Int64)->String {
    if n >= 1_000_000_000 { return String(format:"%.2fB",Double(n)/1_000_000_000) }
    if n >= 1_000_000 { return String(format:"%.2fM",Double(n)/1_000_000) }
    if n >= 1_000 { return String(format:"%.1fK",Double(n)/1_000) }
    return String(n)
}
struct Usage:Decodable,Identifiable {
    let source:String;let session:String;let agent:String;let project:String;let model:String
    let ownTotal:Int64;let subagentTotal:Int64
    let input:Int64;let output:Int64;let cacheRead:Int64;let cacheWrite:Int64;let total:Int64;let latest:Double
    var id:String { source+session+project+model }
}
struct ChildModel:Decodable,Identifiable { let model:String;let total:Int64;var id:String {model} }
struct ActiveChild:Decodable,Identifiable { let source:String;let session:String;let parent:String;let title:String;let total:Int64;let models:[ChildModel];var id:String {source+session} }
struct Source:Decodable { let name:String;let available:Bool }
struct WindowUsage:Decodable {let records:Int;let input:Int64;let output:Int64;let cacheRead:Int64;let cacheWrite:Int64;let total:Int64;let startsAt:Double;let through:Double}
struct Subscription:Decodable,Identifiable { let id:String;let source:String;let label:String;let used:Double?;let resetsAt:Double?;let observed:Double?;let state:String;var localUsage:WindowUsage?=nil }
// A stale warning remains useful until its known reset; missing windows are not zero.
func quotaWarnings(_ subscriptions:[Subscription], now:Double)->[Subscription] {
    subscriptions.filter {
        guard let used=$0.used, used.isFinite, (0...100).contains(used),
              let reset=$0.resetsAt, reset>now, let observed=$0.observed,
              observed.isFinite, observed<=now+60 else {return false}
        return quotaLevel(used)>0
    }
}
func subscriptionWarningLevel(_ subscriptions:[Subscription], now:Double)->Int {
    quotaWarnings(subscriptions,now:now).map {quotaLevel($0.used!)}.max() ?? 0
}
struct LiveSession:Decodable {let source:String;let session:String;let name:String}
struct CompactionSummary:Decodable {let source:String;let session:String;let count:Int;let durationSeconds:Double;let durationsRecorded:Int;let beforeTokens:Int64?;let afterTokens:Int64?;let lastAt:Double}
struct Snapshot:Decodable {let compactions:[CompactionSummary]?;let activeSessions:[LiveSession]?; let rows:[Usage];let activeChildren:[ActiveChild];let subscriptions:[Subscription];let notices:[String];let sources:[Source];let indexing:Bool;let updated:Double }
struct Group:Identifiable {
    let id:String;let title:String;let subtitle:String;let rows:[Usage];let active:Bool
    var total:Int64 { rows.reduce(0){$0+$1.total} }
}
struct SourceConfiguration: Codable, Equatable {
    var usage: [String]
    var subscriptions: [String]
    var paths: [String:String] = [:]
    var handoff: Bool
    static func defaults(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> SourceConfiguration {
        let paths = ["Claude":".claude/projects", "Codex":".codex/sessions", "OpenCode":".local/share/opencode/opencode.db"]
        let detected = ["Claude","Codex","OpenCode"].filter { FileManager.default.fileExists(atPath: home.appendingPathComponent(paths[$0]!).path) }
        return SourceConfiguration(usage: detected, subscriptions: detected.filter { $0 != "OpenCode" }, handoff: FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/handoff/.registry").path))
    }
    var json: String { String(data: try! JSONEncoder().encode(self), encoding: .utf8)! }
}
final class Store:ObservableObject {
    @Published var data:Snapshot?
    @Published var loading=false
    @Published var error:String?
    @Published var days=1
    @Published var tab="Agents"
    @Published var expanded:Set<String>=[]
    @Published var sourceConfiguration: SourceConfiguration
    @Published var setupMessage: String?
    @Published var installingObserver = false
    let preferences:UserDefaults
    @Published private(set) var refreshSeconds:Int
    init(preferences:UserDefaults = .standard) {
        self.preferences=preferences
        sourceConfiguration = preferences.data(forKey:"sourceConfiguration").flatMap { try? JSONDecoder().decode(SourceConfiguration.self,from:$0) } ?? SourceConfiguration.defaults()
        let saved=preferences.integer(forKey:"refreshSeconds")
        refreshSeconds=(5...3600).contains(saved) ? saved : 30
    }
    @discardableResult func configureRefresh(_ seconds:Int)->Bool {
        guard (5...3600).contains(seconds) else{return false}
        refreshSeconds=seconds;preferences.set(seconds,forKey:"refreshSeconds");scheduleTimer();return true
    }
    func saveSources() {
        preferences.set(try? JSONEncoder().encode(sourceConfiguration),forKey:"sourceConfiguration")
        data=nil;onUpdate?();refresh()
    }
    func sourcePath(_ source: String) -> String {
        sourceConfiguration.paths[source] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(["Claude":".claude/projects","Codex":".codex/sessions","OpenCode":".local/share/opencode/opencode.db"][source]!).path
    }
    func chooseSource(_ source: String) {
        let panel=NSOpenPanel();panel.canChooseDirectories=source != "OpenCode";panel.canChooseFiles=source == "OpenCode"
        panel.prompt=source == "OpenCode" ? "Choose database" : "Choose session folder"
        if panel.runModal() == .OK, let url=panel.url {sourceConfiguration.paths[source]=url.path;saveSources()}
    }
    var observerInstalled: Bool {
        let home=FileManager.default.homeDirectoryForCurrentUser
        guard let bytes=try? Data(contentsOf:home.appendingPathComponent(".claude/settings.json")),
              let settings=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
              let line=settings["statusLine"] as? [String:Any], let command=line["command"] as? String else{return false}
        return command.contains("TokenMonitor/claude-observer/claude_statusline.py")
    }
    func subscriptionStatus(_ source: String) -> String {
        if source == "Claude" && !observerInstalled {return "Setup needed"}
        let reports=(data?.subscriptions ?? []).filter {$0.source == source && $0.used != nil}
        if reports.contains(where: {($0.resetsAt ?? 0) > Date().timeIntervalSince1970 && Date().timeIntervalSince1970 - ($0.observed ?? 0) <= 300}) {return "Connected · local report available"}
        return "Waiting for report"
    }
    func installObserver() {
        let alert=NSAlert();alert.messageText="Set up Claude subscription reports?"
        alert.informativeText="This adds a quota observer to ~/.claude/settings.json. Your existing status line and other settings are preserved and backed up. It does not sign in or read credentials. Existing Claude sessions may need a restart."
        alert.addButton(withTitle:"Set up");alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        guard let resources=Bundle.main.resourceURL else{return}
        installingObserver=true;setupMessage=nil
        DispatchQueue.global(qos:.utility).async {
            let process=Process();let pipe=Pipe()
            let python=resources.appendingPathComponent("python/bin/python3").path
            process.executableURL=URL(fileURLWithPath:python)
            process.arguments=["-B","-E","-s",resources.appendingPathComponent("install_claude_observer.py").path,"--python",python]
            process.standardOutput=FileHandle.nullDevice;process.standardError=pipe
            var message="Observer installed. Waiting for Claude to publish a report."
            do {try process.run();let detail=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit();if process.terminationStatus != 0 {message="Setup failed: " + String(decoding:detail.suffix(700),as:UTF8.self)}} catch {message="Setup failed: " + error.localizedDescription}
            let result=message
            DispatchQueue.main.async {self.installingObserver=false;self.setupMessage=result;self.refresh()}
        }
    }
    func scheduleTimer() {
        timer?.invalidate()
        timer=Timer(timeInterval:Double(refreshSeconds),repeats:true){[weak self] _ in self?.refresh()}
        RunLoop.main.add(timer!,forMode:.common)
    }
    var timer:Timer?
    var process:Process?
    var onUpdate:(()->Void)?
    var total:Int64 { data?.rows.reduce(0){$0+$1.total} ?? 0 }
    func start() { refresh();scheduleTimer() }
    func refresh() {
        guard !loading else{return}
        guard let path=Bundle.main.path(forResource:"collector",ofType:"py") else{error="Collector is missing from the app bundle.";return}
        loading=true;error=nil
        let requestedDays=days
        let requestedSources=sourceConfiguration
        DispatchQueue.global(qos:.utility).async {
            let p=Process();p.executableURL=Bundle.main.resourceURL?.appendingPathComponent("python/bin/python3") ?? URL(fileURLWithPath:"/usr/bin/python3");p.arguments=["-B","-E","-s",path,"--days",String(requestedDays),"--config",requestedSources.json]
            let stdout=Pipe();p.standardOutput=stdout
            let logURL=FileManager.default.temporaryDirectory.appendingPathComponent("TokenMonitor-"+UUID().uuidString)
            FileManager.default.createFile(atPath:logURL.path,contents:nil,attributes:[.posixPermissions:0o600])
            let err=try? FileHandle(forWritingTo:logURL);p.standardError=err ?? FileHandle.nullDevice
            var result:Snapshot?;var failure:String?
            do {
                try p.run()
                DispatchQueue.main.async { self.process=p }
                let bytes=stdout.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
                if p.terminationStatus==0 { result=try JSONDecoder().decode(Snapshot.self,from:bytes) }
                else { failure=String((try? String(contentsOf:logURL,encoding:.utf8))?.suffix(700) ?? "Collector failed") }
            } catch { failure=error.localizedDescription }
            try? err?.close();try? FileManager.default.removeItem(at:logURL)
            let output=result;let problem=failure
            DispatchQueue.main.async {
                self.process=nil;self.loading=false
                if requestedDays != self.days || requestedSources != self.sourceConfiguration { self.refresh();return }
                if let output=output { self.data=output }
                self.error=problem;self.onUpdate?()
                if output?.indexing==true { DispatchQueue.main.asyncAfter(deadline:.now()+2){self.refresh()} }
            }
        }
    }
    var groups:[Group] {
        let rows=data?.rows ?? []
        let grouped=Dictionary(grouping:rows){ r in tab=="Models" ? r.model : tab=="Projects" ? r.project : r.source+":"+r.session }
        return grouped.map { key,rows in
            let first=rows[0]
            let title=tab=="Models" ? key : tab=="Projects" ? URL(fileURLWithPath:key).lastPathComponent : first.agent
            let subtitle=tab=="Models" ? Set(rows.map(\.source)).sorted().joined(separator:" · ") : tab=="Projects" ? key.replacingOccurrences(of:NSHomeDirectory(),with:"~") : first.source+" · "+first.session.prefix(8)
            return Group(id:key,title:title,subtitle:subtitle,rows:rows,active:tab=="Agents" && (data?.activeSessions ?? []).contains {$0.source==first.source && $0.session==first.session})
        }.sorted { if $0.active != $1.active {return $0.active};return $0.total == $1.total ? $0.id<$1.id : $0.total>$1.total }
    }
}
struct GroupRow:View {
    @ObservedObject var store:Store
    let group:Group
    var body:some View {
        VStack(alignment:.leading,spacing:9) {
            Button { if store.expanded.contains(group.id){store.expanded.remove(group.id)}else{store.expanded.insert(group.id)} } label: {
                HStack(spacing:10) {
                    Image(systemName:store.expanded.contains(group.id) ? "chevron.down":"chevron.right").font(.system(size:10,weight:.bold)).foregroundStyle(accent).frame(width:12)
                    VStack(alignment:.leading,spacing:4){Text(group.title).font(.system(size:13,weight:.semibold)).lineLimit(1);Text(group.subtitle).font(.system(size:10)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)}
                    if store.tab=="Agents" {sessionBadge(group.active)}
                    Spacer();Text(compact(group.total)).font(.system(size:16,weight:.semibold,design:.rounded)).foregroundStyle(accent)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            GeometryReader { g in Capsule().fill(accent.opacity(0.45)).frame(width:max(2,g.size.width*Double(group.total)/Double(max(1,store.groups.map(\.total).max() ?? 1)))) }.frame(height:3)
            if store.expanded.contains(group.id) {
                HStack(spacing:14) {
                    metric("Input",group.rows.reduce(0){$0+$1.input})
                    metric("Output",group.rows.reduce(0){$0+$1.output})
                    metric("Cache read",group.rows.reduce(0){$0+$1.cacheRead})
                    metric("Cache write",group.rows.reduce(0){$0+$1.cacheWrite})
                }.padding(.vertical,5)
                if store.tab=="Agents" {
                    compactionPanel
                    ownershipSection("PARENT USAGE",key:\Usage.ownTotal)
                    if group.rows.contains(where:{$0.subagentTotal>0}) {
                        ownershipSection("SUBAGENT USAGE",key:\Usage.subagentTotal)
                        Text("Includes active and completed subagents").font(.system(size:9)).foregroundStyle(.secondary)
                    }
                    if !(store.data?.activeChildren ?? []).filter({child in group.rows.contains {$0.source==child.source && $0.session==child.parent}}).isEmpty {
                        Divider().padding(.vertical,4)
                        Text("ACTIVE SUBAGENTS").font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary)
                        Text("Their usage is included above").font(.system(size:9)).foregroundStyle(.secondary)
                    }
                    ForEach((store.data?.activeChildren ?? []).filter { child in group.rows.contains { $0.source==child.source && $0.session==child.parent } }) { child in
                        DisclosureGroup {
                            ForEach(child.models) { model in
                                HStack {Text(model.model);Spacer();Text(compact(model.total))}.font(.system(size:10)).padding(.vertical,3)
                            }
                        } label: {
                            HStack {Text(child.title);Text("Active").foregroundStyle(accent);Spacer();Text(compact(child.total))}.font(.system(size:10))
                        }.tint(accent)
                    }
                }
                if store.tab != "Agents" {
                ForEach(group.rows.sorted {
                    if rowActive($0) != rowActive($1) {return rowActive($0)}
                    return $0.total==$1.total ? $0.id<$1.id : $0.total>$1.total
                }) { row in
                    detailRow(row)
                }
            }
                }
        }.padding(12).background(surface,in:RoundedRectangle(cornerRadius:10))
    }
    var compactionPanel:some View {
        let summary=(store.data?.compactions ?? []).first {item in group.rows.contains {$0.source==item.source && $0.session==item.session}}
        return VStack(alignment:.leading,spacing:7) {
            Label("COMPACTIONS · LIMITED DATA",systemImage:"exclamationmark.triangle.fill").font(.system(size:9,weight:.semibold))
            if let summary=summary {
                Text("\(summary.count) recorded in this period · parent session").font(.system(size:11,weight:.medium))
                if summary.durationsRecorded>0 {
                    Text("Recorded duration: \(Int(summary.durationSeconds.rounded()))s across \(summary.durationsRecorded) of \(summary.count) events").font(.system(size:10))
                } else {Text("Duration: not reported").font(.system(size:10))}
                if let before=summary.beforeTokens, let after=summary.afterTokens {
                    Text("Last context: \(compact(before)) → \(compact(after)) tokens").font(.system(size:10))
                }
                Text("Last: \(Date(timeIntervalSince1970:summary.lastAt).formatted(date:.abbreviated,time:.shortened))").font(.system(size:9))
            } else {
                Text(store.data?.indexing==true ? "Indexing compaction history…" : "No compaction events found in local records for this period.").font(.system(size:10))
            }
            Text("Token spending: not verified. Context sizes are not tokens spent. Records may be incomplete; these figures are not added to usage totals.").font(.system(size:10))
        }.foregroundStyle(quotaColor(1)).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(Color.yellow.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
    }
    func rowSubtitle(_ row:Usage)->String {
        let detail=store.tab=="Projects" ? row.model : URL(fileURLWithPath:row.project).lastPathComponent
        return [row.source,String(row.session.prefix(8)),detail].joined(separator:" · ")
    }
    func detailRow(_ row:Usage)->some View {
                    VStack(alignment:.leading,spacing:3) {
                        HStack {
                            Text(row.agent).lineLimit(1)
                            sessionBadge(rowActive(row))
                            Spacer();Text(compact(row.total)).monospacedDigit()
                        }
                        Text(rowSubtitle(row))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help("Session: "+row.session+"\n"+row.project)
                    }.font(.system(size:10)).padding(.vertical,3)
    }
    func sessionBadge(_ active:Bool)->some View {
        Text(active ? "Active" : "Unverified")
            .font(.system(size:9,weight:.semibold))
            .foregroundStyle(active ? Color(red:0.48,green:0.82,blue:0.66) : Color.secondary)
            .padding(.horizontal,6).padding(.vertical,3)
            .background(active ? Color.green.opacity(0.10) : Color.white.opacity(0.05),in:Capsule())
            .help(active ? "Registered session with a running owner at the last check; it may be idle." : "Not confirmed open at the last check. This may be an old session, missing registration, or an unsupported activity source; it does not prove the session is closed.")
    }
    func rowActive(_ row:Usage)->Bool {
        (store.data?.activeSessions ?? []).contains {$0.source==row.source && $0.session==row.session}
    }
    func ownershipSection(_ title:String,key:KeyPath<Usage,Int64>)->some View {
        let rows=group.rows.filter {$0[keyPath:key]>0}
        let models=Dictionary(grouping:rows,by: \.model)
        let names=models.keys.sorted {
            let left=models[$0]!.reduce(Int64(0)){$0+$1[keyPath:key]}
            let right=models[$1]!.reduce(Int64(0)){$0+$1[keyPath:key]}
            return left==right ? $0<$1 : left>right
        }
        return VStack(alignment:.leading,spacing:9) {
            HStack {
                Text(title).font(.system(size:9,weight:.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(compact(rows.reduce(Int64(0)){$0+$1[keyPath:key]})).font(.system(size:11,weight:.semibold))
            }
            ForEach(names,id:\.self) { name in
                DisclosureGroup {
                    ForEach((models[name] ?? []).sorted {$0[keyPath:key]>$1[keyPath:key]}) {row in
                        HStack(alignment:.top) {
                            Text(row.project.replacingOccurrences(of:NSHomeDirectory()+"/Documents/YeagerAI/",with:"")).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).help(row.project)
                            Spacer()
                            Text(compact(row[keyPath:key])).monospacedDigit()
                        }.font(.system(size:9)).padding(.vertical,3)
                    }
                } label: {
                    HStack {
                        Text(name).lineLimit(1)
                        Spacer()
                        Text(compact((models[name] ?? []).reduce(Int64(0)){$0+$1[keyPath:key]})).monospacedDigit()
                    }.font(.system(size:11))
                }.tint(accent)
            }
        }.padding(.top,9)
    }
    func metric(_ name:String,_ value:Int64)->some View { VStack(alignment:.leading,spacing:3){Text(name).font(.system(size:9)).foregroundStyle(.secondary);Text(compact(value)).font(.system(size:11,weight:.medium)).monospacedDigit()}.frame(maxWidth:.infinity,alignment:.leading) }
}
struct SubscriptionPanel:View {
    let subscriptions:[Subscription]
    var body:some View {
        TimelineView(.periodic(from:.now,by:30)) { context in
            VStack(alignment:.leading,spacing:10) {
                Label("SUBSCRIPTIONS",systemImage:"gauge.with.dots.needle.50percent").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
                ForEach(subscriptions) { quota in
                    let expired=(quota.resetsAt ?? .infinity)<=context.date.timeIntervalSince1970
                    let stale=context.date.timeIntervalSince1970-(quota.observed ?? 0)>300
                    VStack(alignment:.leading,spacing:7) {
                        HStack {
                            Text(quota.source).fontWeight(.semibold)
                            Text(quota.label).foregroundStyle(.secondary)
                            Spacer()
                            if let used=quota.used, !expired {
                                Text(String(format:"%.0f%% used",used)).monospacedDigit().foregroundStyle(quotaColor(quotaLevel(used)))
                            } else { Text(expired ? "Awaiting reset update":"Not available").foregroundStyle(.secondary).font(.system(size:10)) }
                        }.font(.system(size:11))
                        if let used=quota.used, !expired {
                            ProgressView(value:min(100,max(0,used)),total:100).tint(quotaColor(quotaLevel(used)))
                        }
                        if !expired {
                            if let usage=quota.localUsage {
                                Divider().padding(.vertical,3)
                                Text(usage.records>0 ? compact(usage.total)+" local tokens in this window" : "No local token records in this window").font(.system(size:12,weight:.semibold))
                                if usage.records>0 {
                                    HStack {
                                        tokenMetric("Input",usage.input);tokenMetric("Output",usage.output)
                                        tokenMetric("Cache read",usage.cacheRead);tokenMetric("Cache write",usage.cacheWrite)
                                    }
                                }
                                Text("From \(Date(timeIntervalSince1970:usage.startsAt).formatted(date:.abbreviated,time:.shortened)) · through the report below").font(.system(size:9)).foregroundStyle(.secondary)
                            } else if quota.used != nil {
                                Text("Token window unavailable · waiting for a report with its duration").font(.system(size:10)).foregroundStyle(.secondary)
                            }
                        }
                        if let observed=quota.observed {
                            HStack {
                                Text((stale || expired ? "Stale · reported ":"Reported ")+Date(timeIntervalSince1970:observed).formatted(date:.abbreviated,time:.shortened))
                                Spacer()
                                if let reset=quota.resetsAt, !expired { Text("Resets in "+countdown(reset-context.date.timeIntervalSince1970)) }
                            }.font(.system(size:9)).foregroundStyle(.secondary)
                        } else {
                            Text(quota.source=="Claude" ? "Waiting for Claude’s status-line update." : "Waiting for a Codex quota record.").font(.system(size:10)).foregroundStyle(.secondary)
                        }
                    }.padding(11).background(surface,in:RoundedRectangle(cornerRadius:9))
                }
                Text("Local records only · not a conversion to the percentage. Model and cache weighting can differ; other devices or missing logs are excluded. Local records may include API usage or other accounts; indexing can leave totals incomplete. Includes parent and subagent tokens once; windows overlap and must not be added together.").font(.system(size:10)).foregroundStyle(Color(red:0.91,green:0.74,blue:0.48))
                Text("Provider-reported limits · separate from token totals").font(.system(size:9)).foregroundStyle(.secondary)
                Divider().padding(.vertical,3)
            }
        }
    }
    func tokenMetric(_ label:String,_ value:Int64)->some View {
        VStack(alignment:.leading,spacing:3) {
            Text(label).font(.system(size:9)).foregroundStyle(.secondary)
            Text(compact(value)).font(.system(size:10,weight:.medium)).monospacedDigit()
        }.frame(maxWidth:.infinity,alignment:.leading)
    }
    func countdown(_ seconds:Double)->String {
        let minutes=max(1,Int(ceil(seconds/60)))
        if minutes>=1440 {return "\(minutes/1440)d \((minutes%1440)/60)h"}
        if minutes>=60 {return "\(minutes/60)h \(minutes%60)m"}
        return "\(minutes)m"
    }
}
struct AlertLegend:View {
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Alert legend").font(.system(size:13,weight:.semibold))
            row("Red · 90% or more used.",symbol:"exclamationmark.circle.fill",color:quotaColor(2))
            row("Yellow · 75% to below 90% used.",symbol:"exclamationmark.circle.fill",color:quotaColor(1))
            row("No badge · No reported window at 75% or above.",symbol:"chart.bar.xaxis",color:.secondary)
            Text("Red takes priority across Claude and Codex. The menu bar badge and Subscriptions dot use the same thresholds.")
                .font(.system(size:11)).foregroundStyle(.secondary)
            Text("Older warnings retain their color until the reported reset. Expired or missing windows are unknown; no badge does not guarantee available allowance. Open Subscriptions to check report times.")
                .font(.system(size:11)).foregroundStyle(.secondary)
        }
    }
    func row(_ title:String,symbol:String,color:Color)->some View {
        HStack(alignment:.top,spacing:10) {
            Image(systemName:symbol).foregroundStyle(color).frame(width:17)
            Text(title)
        }.font(.system(size:11))
    }
}
struct SourceSettings: View {
    @ObservedObject var store: Store
    func binding(_ source:String, subscriptions:Bool=false) -> Binding<Bool> {
        Binding(get:{ (subscriptions ? store.sourceConfiguration.subscriptions : store.sourceConfiguration.usage).contains(source) },set:{ enabled in
            if subscriptions {store.sourceConfiguration.subscriptions.removeAll {$0 == source};if enabled {store.sourceConfiguration.subscriptions.append(source)}}
            else {store.sourceConfiguration.usage.removeAll {$0 == source};if enabled {store.sourceConfiguration.usage.append(source)}}
            store.saveSources()
        })
    }
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            Text("Sources & subscriptions").font(.headline)
            Text("Changes save immediately. Disabled sources retain their history but leave totals and alerts.").font(.caption).foregroundStyle(.secondary)
            ForEach(["Claude","Codex","OpenCode"],id:\.self) {source in
                Toggle(source + " usage",isOn:binding(source))
                Text(store.sourcePath(source)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Text(FileManager.default.fileExists(atPath:store.sourcePath(source)) ? "Detected" : "Not found").font(.caption)
                    Spacer()
                    Button("Choose location…") {store.chooseSource(source)}
                    Button("Default") {store.sourceConfiguration.paths.removeValue(forKey:source);store.saveSources()}
                }
            }
            Divider()
            Text("Subscription reports").fontWeight(.semibold)
            ForEach(["Claude","Codex"],id:\.self) {source in
                Toggle(source,isOn:binding(source,subscriptions:true))
                if store.sourceConfiguration.subscriptions.contains(source) {Text(store.subscriptionStatus(source)).font(.caption).foregroundStyle(.secondary)}
            }
            if store.sourceConfiguration.subscriptions.contains("Claude") {
                Button(store.installingObserver ? "Setting up…" : "Set up Claude reports…") {store.installObserver()}.disabled(store.installingObserver)
                Text("Uses the standard ~/.claude/settings.json. Custom session folders change usage imports only.").font(.caption).foregroundStyle(.secondary)
            }
            if let message=store.setupMessage {Text(message).font(.caption).textSelection(.enabled)}
            Text("Codex reports arrive from its selected session folder. OpenCode subscription quotas are not supported. No login or credentials are collected. Multiple accounts cannot be distinguished: reports and local totals must not be treated as account-specific.").font(.caption).foregroundStyle(Color.yellow)
            Divider()
            Toggle("Handoff agent names & activity",isOn:Binding(get:{store.sourceConfiguration.handoff},set:{store.sourceConfiguration.handoff=$0;store.saveSources()}))
            Text("Optional, read-only integration. Without it, sessions use their client and short ID with Unverified status. Parent/subagent usage still works.").font(.caption).foregroundStyle(.secondary)
        }.font(.system(size:11)).disabled(store.loading || store.installingObserver)
    }
}
struct TokenSettings:View {
    @ObservedObject var store:Store
    let close:()->Void
    @State private var seconds=""
    @State private var invalid=false
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:18) {
                Label("Settings",systemImage:"slider.horizontal.3").font(.headline)
                Text("Refresh interval").font(.system(size:13,weight:.medium))
                HStack {
                    Text("Check every")
                    TextField("30",text:$seconds).textFieldStyle(.roundedBorder).frame(width:80).accessibilityLabel("Refresh interval in seconds")
                    Text("seconds")
                }.font(.system(size:12))
                Text("Reads local token records and subscription snapshots. Enter 5–3,600 seconds. This does not force Claude or Codex to publish a new quota report.").font(.system(size:11)).foregroundStyle(.secondary)
                if invalid {Text("Enter a whole number from 5 to 3,600.").font(.caption).foregroundStyle(.red)}
                Button("Save settings") {
                    guard let value=Int(seconds.trimmingCharacters(in:.whitespaces)),store.configureRefresh(value) else{invalid=true;return}
                    close()
                }.buttonStyle(.borderedProminent).tint(accent).foregroundStyle(.black)
                Text("Saved across restarts. An active collection continues; the new interval applies to the next scheduled refresh. Initial history indexing continues in short batches.").font(.system(size:11)).foregroundStyle(.secondary)
                Divider().padding(.vertical,3)
                SourceSettings(store:store)
                Divider()
                UpdateSettings()
                Divider()
                AlertLegend()
            }.padding(20)
        }.onAppear {seconds=String(store.refreshSeconds)}
    }
}
struct Dashboard:View {
    @ObservedObject var store:Store
    @State var information=false
    @State private var settings=false
    @State private var page="Usage"
    @State private var subscriptionProvider="Claude"
    var body:some View {
        VStack(spacing:0) {
            VStack(alignment:.leading,spacing:15) {
                HStack { Label("TOKEN MONITOR",systemImage:"chart.bar.xaxis").font(.system(size:11,weight:.semibold)).tracking(1.4);Spacer();Text("v" + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")).font(.system(size:9)).padding(6).background(.white.opacity(0.1),in:Capsule()) }
                if !information && !settings {
                TimelineView(.periodic(from:.now,by:30)) { context in
                    HStack(spacing:4) {
                        pageButton("Usage",warningLevel:0)
                        pageButton("Subscriptions",warningLevel:subscriptionWarningLevel(store.data?.subscriptions ?? [],now:context.date.timeIntervalSince1970))
                    }.padding(3).background(.black.opacity(0.15),in:RoundedRectangle(cornerRadius:9))
                }
                }
                if !information && !settings && page=="Usage" {
                HStack(alignment:.firstTextBaseline){Text(compact(store.total)).font(.system(size:39,weight:.semibold,design:.rounded));Text("recorded tokens").font(.system(size:12)).foregroundStyle(.white.opacity(0.7));Spacer()}
                Picker("Period",selection:$store.days){Text("Today").tag(1);Text("7 days").tag(7);Text("30 days").tag(30)}.pickerStyle(.segmented).disabled(store.loading)
                HStack(spacing:14){stat("Input",\.input);stat("Output",\.output);stat("Cache read",\.cacheRead);stat("Cache write",\.cacheWrite)}
                } else if !information && !settings {
                    Text("Your subscription limits").font(.system(size:24,weight:.semibold,design:.rounded))
                    Text("Allowance used and time until reset").font(.system(size:12)).foregroundStyle(.white.opacity(0.65))
                }
            }.padding(20).background(LinearGradient(colors:[Color(red:0.19,green:0.22,blue:0.39),Color(red:0.16,green:0.19,blue:0.28)],startPoint:.topLeading,endPoint:.bottomTrailing))
            if settings {
                TokenSettings(store:store) { settings=false }
            } else if information {
                ScrollView {
                    VStack(alignment:.leading,spacing:15) {
                        Text("About these measurements").font(.headline)
                        Text("Reads local Claude Code and Codex session logs, plus the OpenCode database. Source files are never modified. Usage appears after the client records it—not necessarily during generation.")
                        Text("Input, output, cache reads and cache writes are separate categories. Cached tokens are included once. Reasoning is not added again to output.")
                        Text("Agent status is consistent across Agents, Models, and Projects: green Active means a registered session with a running owner at the last check, including idle sessions. Gray Unverified means we cannot confirm it is open; it is not proof of closure. Session IDs distinguish reused names. Active agent entries sort first; model and project cards remain ranked by total usage.")
                        Text("Model aliases such as default remain unresolved. Agent names use the local handoff registry when available; other sessions show their app and short ID. Historical names may be unavailable. Parent totals include subagent usage. Completed subagents are hidden; their usage stays in the subtotal. Individual subagents appear only with recent running evidence (within five minutes); missing status never removes their spend.")
                        Text("Token totals cover local records, not an account-wide bill. Subscription bars separately show provider-reported limits. Codex quota snapshots come from its local logs; Claude limits arrive through a status-line observer that preserves the existing footer. Readings older than five minutes are marked stale. An expired window is unknown until a new report arrives. No price estimates or budget alerts in this draft.")
                        Text("Refreshes every \(store.refreshSeconds) seconds. Initial indexing runs in bounded batches; totals are partial until it finishes. Date ranges use this Mac’s local calendar.")
                        Text("Only usage metadata is cached in ~/Library/Application Support/TokenMonitor. Conversation text is not copied into the cache.")
                    }.font(.system(size:12)).foregroundStyle(.secondary).padding(20)
                }
            } else if page=="Subscriptions" {
                Picker("Provider",selection:$subscriptionProvider) {
                    ForEach(store.sourceConfiguration.subscriptions,id:\.self) {Text($0).tag($0)}
                }.pickerStyle(.segmented).labelsHidden().padding(14)
                ScrollView {
                    VStack(alignment:.leading,spacing:12) {
                        if let error=store.error { notice("Refresh failed · previous reports retained\n"+error) }
                        if store.data == nil {
                            Text("Loading subscription reports…").font(.caption).foregroundStyle(.secondary).padding(.vertical,20)
                        }
                        if store.sourceConfiguration.subscriptions.isEmpty {
                            Text("No subscription providers enabled. Add Claude or Codex in Settings → Sources & subscriptions.").font(.caption)
                            Button("Set up subscriptions") {settings=true}
                        } else {
                            Text(store.subscriptionStatus(subscriptionProvider)).font(.caption).foregroundStyle(.secondary)
                        }
                        SubscriptionPanel(subscriptions:(store.data?.subscriptions ?? []).filter { $0.source==subscriptionProvider })

                    }.padding(14)
                }
            } else {
                Picker("Group by",selection:$store.tab){Text("Agents").tag("Agents");Text("Models").tag("Models");Text("Projects").tag("Projects")}.pickerStyle(.segmented).padding(14)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:10) {
                        if let error=store.error { notice("Refresh failed · saved view retained\n"+error) }
                        ForEach(store.data?.notices ?? [],id:\.self){notice($0)}
                        if store.groups.isEmpty {
                            VStack(spacing:12){Image(systemName:store.loading ? "hourglass":"chart.bar").font(.system(size:26));Text(store.loading ? "Reading local usage…":"No recorded usage in this period");Text(store.sourceConfiguration.usage.isEmpty ? "Enable a client in Settings → Sources & subscriptions to get started." : "Try 7 or 30 days. Missing records are not proof of zero usage.").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)}.frame(maxWidth:.infinity).padding(.vertical,35)
                        }
                        ForEach(store.groups){GroupRow(store:store,group:$0)}
                    }.padding(.horizontal,14).padding(.bottom,14)
                }
            }
            if information || settings {
                HStack {
                    Spacer()
                    Button("Back") { information=false;settings=false }
                }.buttonStyle(.plain).font(.system(size:11)).padding(.horizontal,14).padding(.vertical,10)
            }
            Divider()
            HStack(spacing:8) {
                if store.loading { ProgressView().controlSize(.small) }
                VStack(alignment:.leading,spacing:3) {
                    Text(footerStatus).font(.system(size:10))
                    Text("Refresh: every \(store.refreshSeconds)s · Checked \(store.data.map{Date(timeIntervalSince1970:$0.updated).formatted(date:.omitted,time:.shortened)} ?? "—")")
                        .font(.system(size:9)).foregroundStyle(.secondary)
                }
                Spacer()
                Button{store.refresh()}label:{Image(systemName:"arrow.clockwise").frame(width:22,height:28)}.disabled(store.loading).help(page=="Usage" ? "Refresh usage":"Read latest local quota reports")
                Button{settings=false;information.toggle()}label:{Image(systemName:"info.circle").frame(width:22,height:28)}.help("About Token Monitor").accessibilityLabel("About Token Monitor")
                Button{information=false;settings.toggle()}label:{Image(systemName:"gearshape").frame(width:22,height:28)}.help("Settings").accessibilityLabel("Settings")
                Button{NSApp.terminate(nil)}label:{Image(systemName:"power").frame(width:22,height:28)}.help("Quit Token Monitor").accessibilityLabel("Quit Token Monitor")
            }.buttonStyle(.plain).padding(14)
        }.frame(width:460,height:700).background(canvasColor).foregroundStyle(Color(white:0.88)).preferredColorScheme(.dark)
        .onChange(of:store.sourceConfiguration.subscriptions) { _, providers in
            if !providers.contains(subscriptionProvider) {subscriptionProvider=providers.first ?? "Claude"}
        }
        .onAppear {if !store.sourceConfiguration.subscriptions.contains(subscriptionProvider) {subscriptionProvider=store.sourceConfiguration.subscriptions.first ?? "Claude"}}
        .onChange(of:store.days){_,_ in store.expanded=[];store.refresh()}
        .onChange(of:store.tab){_,_ in store.expanded=[]}
    }
    var footerStatus:String {
        if store.loading {return page=="Usage" ? "Reading usage records…" : "Reading subscription reports…"}
        if store.error != nil {return "Refresh failed · saved readings retained"}
        if store.data == nil {return "Waiting for first reading"}
        if store.data?.indexing==true {return "Indexing history · totals are partial"}
        return page=="Usage" ? "Showing saved token usage" : "Showing saved subscription reports"
    }
    func pageButton(_ title:String,warningLevel:Int)->some View {
        Button { page=title;information=false;settings=false } label: {
            HStack(spacing:6) {
                Text(title).font(.system(size:12,weight:.semibold))
                if warningLevel>0 {Circle().fill(quotaColor(warningLevel)).frame(width:6,height:6).accessibilityLabel(warningLevel==2 ? "Subscription usage at least 90 percent":"Subscription usage at least 75 percent")}
            }.frame(maxWidth:.infinity).padding(.vertical,8)
                .background(page==title ? Color.white.opacity(0.17):Color.clear,in:RoundedRectangle(cornerRadius:6))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(page==title ? .isSelected:[])
    }
    func stat(_ name:String,_ key:KeyPath<Usage,Int64>)->some View { VStack(alignment:.leading,spacing:4){Text(name).font(.system(size:9)).foregroundStyle(.white.opacity(0.6));Text(compact(store.data?.rows.reduce(0){$0+$1[keyPath:key]} ?? 0)).font(.system(size:12,weight:.medium)).monospacedDigit()}.frame(maxWidth:.infinity,alignment:.leading) }
    func notice(_ text:String)->some View { Text(text).font(.system(size:10)).foregroundStyle(Color(red:0.91,green:0.74,blue:0.48)).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(Color.orange.opacity(0.07),in:RoundedRectangle(cornerRadius:8)) }
}
final class StatusBadgeView:NSView {
    var level=0 {didSet {needsDisplay=true}}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func draw(_ dirtyRect:NSRect) {
        NSColor(quotaColor(level)).setFill()
        NSBezierPath(ovalIn:bounds).fill()
        let text=NSAttributedString(string:"!",attributes:[.font:NSFont.systemFont(ofSize:10,weight:.heavy),.foregroundColor:NSColor.black])
        text.draw(at:NSPoint(x:bounds.midX-text.size().width/2,y:bounds.midY-text.size().height/2))
    }
}
final class AppDelegate:NSObject,NSApplicationDelegate,NSPopoverDelegate {
    let store=Store();let popover=NSPopover();var item:NSStatusItem!;var global:Any?;var local:Any?
    let badge=StatusBadgeView(frame:.zero)
    var badgeTimer:Timer?
    func applicationDidFinishLaunching(_ n:Notification) {
        AppUpdates.shared.start { [weak self] in self?.store.loading == true }
        launchDiagnostic("didFinish")
        DispatchQueue.main.asyncAfter(deadline:.now()+2) { launchDiagnostic("status",self.item) }
        NSApp.setActivationPolicy(.accessory)
        let autosaveName="TokenMonitor-status"
        let positionKey="NSStatusItem Preferred Position "+autosaveName
        if UserDefaults.standard.object(forKey:positionKey)==nil {
            UserDefaults.standard.set(0,forKey:positionKey)
        }
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.autosaveName=autosaveName
        item.isVisible=true
        item.button?.image=NSImage(systemSymbolName:"chart.bar.xaxis",accessibilityDescription:"Token Monitor");item.button?.image?.isTemplate=true
        item.button?.target=self;item.button?.action=#selector(toggle)
        if let button=item.button {
            badge.translatesAutoresizingMaskIntoConstraints=false;badge.isHidden=true
            badge.setAccessibilityElement(false);button.addSubview(badge)
            NSLayoutConstraint.activate([
                badge.widthAnchor.constraint(equalToConstant:13),badge.heightAnchor.constraint(equalToConstant:13),
                badge.trailingAnchor.constraint(equalTo:button.trailingAnchor,constant:-1),
                badge.bottomAnchor.constraint(equalTo:button.bottomAnchor,constant:1)
            ])
        }
        popover.behavior = .transient;popover.appearance=NSAppearance(named:.darkAqua);popover.delegate=self
        popover.contentViewController=NSHostingController(rootView:Dashboard(store:store));popover.contentSize=NSSize(width:460,height:700)
        store.onUpdate={ [weak self] in self?.updateStatusIcon() }
        badgeTimer=Timer(timeInterval:30,repeats:true){[weak self] _ in self?.updateStatusIcon()}
        RunLoop.main.add(badgeTimer!,forMode:.common)
        updateStatusIcon()
        store.start()
        if CommandLine.arguments.contains("--show"){DispatchQueue.main.asyncAfter(deadline:.now()+0.4){self.toggle()}}
    }
    func updateStatusIcon() {
        let now=Date().timeIntervalSince1970
        let subscriptions=store.data?.subscriptions ?? []
        let warnings=quotaWarnings(subscriptions,now:now)
        badge.level=subscriptionWarningLevel(subscriptions,now:now);badge.isHidden=badge.level==0
        var lines=["Token Monitor · "+compact(store.total)+" recorded tokens"]
        for quota in warnings {
            lines.append("\(quota.source) · \(quota.label) · \(Int(quota.used!))% used" + (now-(quota.observed ?? 0)>300 ? " · stale report" : ""))
        }
        if warnings.isEmpty {lines.append("No reported subscription warning · open Subscriptions for availability")}
        if store.error != nil {lines.append("Refresh failed · previous reports retained")}
        item.button?.toolTip=lines.joined(separator:"\n")
        item.button?.setAccessibilityLabel(lines.joined(separator:"; "))
    }
    @objc func toggle(){
        if popover.isShown {popover.performClose(nil);return}
        guard let b=item.button else{return}
        NSApp.activate(ignoringOtherApps:true);popover.show(relativeTo:b.bounds,of:b,preferredEdge:.minY);popover.contentViewController?.view.window?.makeKey()
        clearMonitors()
        global=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.otherMouseDown]){[weak self] _ in self?.popover.performClose(nil)}
        local=NSEvent.addLocalMonitorForEvents(matching:[.keyDown,.leftMouseDown,.rightMouseDown]){[weak self] event in
            guard let self=self else{return event}
            if event.type == .keyDown && event.keyCode==53 {self.popover.performClose(nil);return nil}
            if event.type != .keyDown && event.window !== self.popover.contentViewController?.view.window && event.window !== self.item.button?.window {self.popover.performClose(nil)}
            return event
        }
    }
    func clearMonitors(){if let g=global{NSEvent.removeMonitor(g);global=nil};if let l=local{NSEvent.removeMonitor(l);local=nil}}
    func popoverDidClose(_ n:Notification){clearMonitors()}
    func applicationDidResignActive(_ n:Notification){popover.performClose(nil)}
    func applicationWillTerminate(_ n:Notification){clearMonitors();badgeTimer?.invalidate();store.timer?.invalidate();if store.process?.isRunning==true{store.process?.terminate()}}
}
if CommandLine.arguments.contains("--updater-self-test") {
    precondition(Bundle.main.bundleIdentifier?.hasPrefix("local.monitor.updater-test.") == true, "Use the isolated updater fixture")
    _ = NSApplication.shared
    AppUpdates.shared.start { false }
    precondition(AppUpdates.shared.failure == nil, "Sparkle configuration must start successfully")
    precondition(!AppUpdates.shared.checks && !AppUpdates.shared.downloads)
    print("PASS: embedded Sparkle starts with automatic checks and downloads disabled")
    exit(0)
}
if CommandLine.arguments.contains("--self-test") {
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
    store.timer?.invalidate();prefs.removePersistentDomain(forName:suite)
    print("PASS: refresh settings validation, timer replacement and persistence")
} else {
    let app=NSApplication.shared
    let delegate=AppDelegate();app.delegate=delegate
    launchDiagnostic("beforeRun")
    DispatchQueue.main.asyncAfter(deadline:.now()+3) {launchDiagnostic("runLoop",delegate.item)}
    withExtendedLifetime(delegate) { app.run() }
}
