// Documentation-only example data. Never compiled into the app.

final class PreviewApplication: NSApplication { override var isActive: Bool { true } }
final class PreviewWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}
let application = PreviewApplication.shared
application.setActivationPolicy(.prohibited)
application.appearance = NSAppearance(named: .darkAqua)
let preferences = UserDefaults(suiteName: "MonitorReadme." + UUID().uuidString)!
let store = Store(preferences: preferences)
let now = Date().timeIntervalSince1970
func usage(_ session:String, _ agent:String, _ model:String, _ input:Int64, _ output:Int64, _ read:Int64, _ write:Int64, _ sub:Int64=0)->Usage {
    let total=input+output+read+write
    return Usage(source:"Claude",session:session,agent:agent,project:"/Projects/genlayer-node",model:model,ownTotal:total-sub,subagentTotal:sub,input:input,output:output,cacheRead:read,cacheWrite:write,total:total,latest:now)
}
func window(_ total:Int64,_ duration:Double,_ remaining:Double)->WindowUsage {
    WindowUsage(records:240,input:total/100,output:total/50,cacheRead:total*96/100,cacheWrite:total/100,total:total,startsAt:now+remaining-duration,through:now)
}
store.data=Snapshot(compactions:[],activeSessions:[LiveSession(source:"Claude",session:"a1b2c3d4-example",name:"genlayer-node-2")],rows:[
    usage("a1b2c3d4-example","genlayer-node-2","claude-opus-4-1",240_000,760_000,30_000_000,1_000_000),
    usage("a1b2c3d4-example","genlayer-node-2","claude-sonnet-4",100_000,300_000,7_500_000,100_000,8_000_000),
    usage("e5f6a7b8-example","genlayer-consensus-3","claude-opus-4-1",100_000,400_000,19_000_000,500_000)
],activeChildren:[],subscriptions:[
    Subscription(id:"claude-five",source:"Claude",label:"5 hours",used:38,resetsAt:now+10_800,observed:now,state:"fresh",localUsage:window(24_000_000,18_000,10_800)),
    Subscription(id:"claude-week",source:"Claude",label:"7 days",used:82,resetsAt:now+172_800,observed:now,state:"fresh",localUsage:window(2_460_000_000,604_800,172_800))
],notices:[],sources:[Source(name:"Claude",available:true),Source(name:"Codex",available:true),Source(name:"OpenCode",available:true)],indexing:false,updated:now)
store.expanded=["Claude:a1b2c3d4-example"]

let view = NSHostingView(rootView: Dashboard(store: store).environment(\.controlActiveState, .active))
view.frame = NSRect(x: 0, y: 0, width: 460, height: 700)
let window = PreviewWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.contentView = view
window.appearance = NSAppearance(named: .darkAqua)
view.layoutSubtreeIfNeeded()
RunLoop.main.run(until: Date().addingTimeInterval(1))
view.layoutSubtreeIfNeeded()
let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
view.cacheDisplay(in: view.bounds, to: bitmap)
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: CommandLine.arguments.last!))
