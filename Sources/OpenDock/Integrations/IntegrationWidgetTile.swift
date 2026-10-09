import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class IntegrationRuntime:ObservableObject {
    @Published var business:BusinessReport?
    @Published var stocks:[String:StockReport] = [:]
    @Published var ai:[AIProvider:AIReport] = [:]
    @Published var errors:[String:String] = [:]
    @Published var busy = false
    private var key = ""
    private var lastFetch:[AIProvider:Date] = [:]
    private static var instances:[UUID:IntegrationRuntime] = [:]
    static func forItem(_ id:UUID)->IntegrationRuntime { if let item = instances[id] { return item }; let runtime = IntegrationRuntime(); instances[id] = runtime; return runtime }
    func refresh(kind:WidgetKind,config:[String:String],explicit:Bool) async {
        let requestedKey = "\(kind)-\(config["accountID"] ?? "")-\(config["period"] ?? "today")-\(config["symbols"] ?? config["symbol"] ?? "")-\(config["range"] ?? "1mo")-\(config["stockProvider"] ?? "yahoo")"
        if key != requestedKey { business = nil; stocks = [:]; errors = [:]; key = requestedKey }
        while busy { do { try await Task.sleep(nanoseconds:50_000_000) } catch { return } }
        guard !Task.isCancelled else { return }
        busy = true; defer { busy = false }
        let signature = "\(kind)-\(config["accountID"] ?? "")-\(config["period"] ?? "today")-\(config["symbols"] ?? config["symbol"] ?? "")-\(config["range"] ?? "1mo")-\(config["stockProvider"] ?? "yahoo")"
        if key != signature { business = nil; stocks = [:]; errors = [:]; key = signature }
        if [.stripe,.paddle,.shopify].contains(kind) {
            guard let account = IntegrationDisk.accounts.first(where:{$0.id.uuidString == config["accountID"] && $0.kind == kind.rawValue}) else { return }
            let cacheKey = "business-\(account.id)-\(config["period"] ?? "today")"
            if business == nil { business = IntegrationDisk.read(BusinessReport.self,key:cacheKey) }
            do {
                guard let credentials = try IntegrationKeychain.read(account:account.id.uuidString,allowPrompt:explicit) else { throw IntegrationError.invalid("此账号的钥匙串密钥不可用，请重新连接。") }
                let report = try await BusinessAdapters.load(account:account,credentials:credentials,period:IntegrationPeriod(rawValue:config["period"] ?? "today") ?? .today)
                try IntegrationDisk.write(report,key:cacheKey)
                guard key == signature, !Task.isCancelled else { return }
                business = report; errors["business"] = nil
            } catch { if key == signature, !Task.isCancelled { errors["business"] = error.localizedDescription } }
        } else if [.stock,.watchlist].contains(kind) {
            let symbols = (config["symbols"] ?? config["symbol"] ?? "").split(separator:",").map { $0.trimmingCharacters(in:.whitespaces).uppercased() }.filter(StockAdapters.validSymbol)
            guard !symbols.isEmpty else { return }
            for symbol in symbols.prefix(20) {
                guard key == signature, !Task.isCancelled else { return }
                let cacheKey = "stock-\(symbol)-\(config["range"] ?? "1mo")-\(config["stockProvider"] ?? "yahoo")"
                if stocks[symbol] == nil { stocks[symbol] = IntegrationDisk.read(StockReport.self,key:cacheKey) }
                do {
                    let report:StockReport
                    if config["stockProvider"] == "alpha" { guard let key = try IntegrationKeychain.read(account:"stock-alpha",allowPrompt:explicit)?["key"] else { throw IntegrationError.invalid("请先连接 Alpha Vantage。") }; report = try await StockAdapters.alpha(symbol:symbol,range:config["range"] ?? "1mo",key:key) }
                    else { report = try await StockAdapters.yahoo(symbol:symbol,range:config["range"] ?? "1mo") }
                    try IntegrationDisk.write(report,key:cacheKey)
                    guard key == signature, !Task.isCancelled else { return }
                    stocks[symbol] = report; errors[symbol] = nil
                } catch { if key == signature, !Task.isCancelled { errors[symbol] = error.localizedDescription } }
            }
        } else {
            let providers = (config["providers"] ?? "codex,claude,grok").split(separator:",").compactMap { AIProvider(rawValue:String($0)) }.filter { kind != .aiActivity || $0.supportsActivity }
            for provider in providers {
                guard !Task.isCancelled else { return }
                if ai[provider] == nil { ai[provider] = AIAdapters.cache(provider) }
                let interval:TimeInterval = [.codex,.grok].contains(provider) || kind == .aiActivity ? 60:300
                if !explicit,let last = lastFetch[provider],Date().timeIntervalSince(last) < interval { continue }
                lastFetch[provider] = .now
                do { ai[provider] = try await AIAdapters.load(provider,explicit:explicit); errors[provider.rawValue] = nil }
                catch { errors[provider.rawValue] = error.localizedDescription }
            }
        }
    }
}

struct IntegrationWidgetTile:View {
    let item:DockItem
    var compact:Bool = false
    let onUpdate:(DockItem)->Void
    @StateObject private var runtime:IntegrationRuntime
    @ObservedObject private var coordinator = WidgetPopoverCoordinator.shared
    @State private var config:[String:String] = [:]
    @State private var presented = false
    @State private var setup = false
    @State private var query = ""
    @State private var matches:[StockMatch] = []
    @State private var accountName = ""
    @State private var domain = ""
    @State private var secret = ""
    @State private var clientID = ""
    @State private var status:String?
    @State private var connecting = false
    @State private var aiProvider:AIProvider = .codex
    @State private var claudeDesktopConnected = false
    @State private var hovered:IntegrationPoint?
    init(item:DockItem,compact:Bool = false,onUpdate:@escaping(DockItem)->Void) {
        self.item = item; self.compact = compact; self.onUpdate = onUpdate
        _runtime = StateObject(wrappedValue:IntegrationRuntime.forItem(item.id))
        _config = State(initialValue:item.configuration)
        _setup = State(initialValue:item.configuration["widgetSetupOpen"] == "true")
        _aiProvider = State(initialValue:AIProvider(rawValue:item.configuration["draftAIProvider"] ?? "codex") ?? .codex)
    }
    private var kind:WidgetKind { item.widget ?? .stock }
    private var business:Bool { [.stripe,.paddle,.shopify].contains(kind) }
    private var stock:Bool { [.stock,.watchlist].contains(kind) }
    private var providers:[AIProvider] { (config["providers"] ?? "codex,claude,grok").split(separator:",").compactMap { AIProvider(rawValue:String($0)) }.filter { kind != .aiActivity || $0.supportsActivity } }
    private var selectedAccount:IntegrationAccount? { IntegrationDisk.accounts.first { $0.id.uuidString == config["accountID"] && $0.kind == kind.rawValue } }
    private var accent:Color { selectedAccount?.colorHex.map { Color(hex:$0) } ?? DockTheme.accent }
    private var metric:String { config["metric"] ?? (kind == .paddle ? "net":"revenue") }
    private var currency:BusinessCurrency? { runtime.business?.currencies.first(where:{$0.currency == config["currency"]}) ?? runtime.business?.currencies.first }
    private var symbols:[String] { (config["symbols"] ?? config["symbol"] ?? "").split(separator:",").map(String.init) }
    private var selectedStock:StockReport? { runtime.stocks[config["selectedSymbol"] ?? symbols.first ?? ""] ?? symbols.compactMap { runtime.stocks[$0] }.first }
    private var period:IntegrationPeriod { IntegrationPeriod(rawValue:config["period"] ?? "today") ?? .today }
    private var title:String { config["title"] ?? kind.title }
    private var summary:String {
        if business { if ["orders","paying"].contains(metric) { return currency?.values[metric].map { NSDecimalNumber(decimal:$0).stringValue } ?? "—" }; return IntegrationNumber.money(currency?.values[metric],currency:currency?.currency ?? "USD") }
        if stock { if let value = selectedStock?.current { return value.formatted(.number.precision(.fractionLength(2))) }; return symbols.first ?? "选择股票" }
        if kind == .aiActivity {
            let records = activityRecords, tokens = total(records.map(\.tokens))
            if records.isEmpty { return providers.contains { runtime.ai[$0] != nil } ? "此范围无记录":"连接活动来源" }
            if records.allSatisfy({ $0.tokenCoverage == "unavailable" }) { return "Tokens 未报告" }
            return (records.contains(where: \.estimated) ? "≈ ":records.contains { ["partial","unavailable"].contains($0.tokenCoverage ?? "") } ? "≥ ":"") + tokens.formatted() + " tokens"
        }
        let active = providers.compactMap { provider -> (AIProvider,AIAllowance)? in guard let report = runtime.ai[provider],let value = chosenLimit(report) else { return nil }; return (provider,value) }
        return active.prefix(3).map { "\($0.0.title) \(Int(displayPercent($0.1)))%" }.joined(separator:" · ") .nonempty ?? "连接 AI 服务"
    }
    private var activityRecords:[AIActivityRecord] { let interval = period.interval(); return providers.flatMap { runtime.ai[$0]?.activity ?? [] }.filter { interval.contains($0.date) } }
    private var subtitle:String { if business { return runtime.business?.source ?? "连接只读账号" }; if stock { return selectedStock.map { "\($0.symbol) · \($0.source)" } ?? "真实行情与价格历史" }; return kind == .aiActivity ? period.title:"额度与重置时间" }
    private var refreshKey:String { "\(kind)-\(config["accountID"] ?? "")-\(config["period"] ?? "today")-\(config["symbols"] ?? "")-\(config["range"] ?? "1mo")-\(config["stockProvider"] ?? "yahoo")-\(config["providers"] ?? "codex,claude,grok")-\(config["autoRefresh"] ?? "true")-\(config["refreshMinutes"] ?? "5")" }
    var body:some View {
        Button { NSApp.activate(ignoringOtherApps:true); presented.toggle() } label: {
            Group {
                if kind == .aiLimits,!tileLimits.isEmpty { limitTile }
                else if kind == .aiActivity,!activityRecords.isEmpty,config["activityStyle"] != "totals" { activityTile }
                else { HStack(spacing:8) { Image(systemName:kind.symbol).font(.system(size:19)).foregroundStyle(accent); VStack(alignment:.leading,spacing:3) { Text(summary).font(.system(size:12,weight:.semibold)).lineLimit(1).minimumScaleFactor(0.65); Text(subtitle).font(.system(size:9)).foregroundStyle(.secondary).lineLimit(1) }; Spacer(minLength:0) } }
            }.padding(.horizontal,11).frame(width:compact ? 132:140,height:58).dockGlass(cornerRadius:14,tint:accent.opacity(0.09),interactive:true)
        }.buttonStyle(.plain).help(title).accessibilityElement(children:.ignore).accessibilityLabel(title).accessibilityValue(summary).accessibilityAddTraits(.isButton)
        .popover(isPresented:$presented,arrowEdge:compact ? .leading:.bottom) { popover }
        .onChange(of:presented) { open in if open { coordinator.activeID = item.id } else if coordinator.activeID == item.id { coordinator.activeID = nil } }
        .onChange(of:coordinator.activeID) { id in if id != item.id { presented = false } }
        .onChange(of:item.configuration) { value in if config != value { config = value } }
        .onChange(of:setup) { set("widgetSetupOpen",String($0)) }
        .onChange(of:aiProvider) { provider in
            set("draftAIProvider",provider.rawValue); secret = ""
            let connection = AIAdapters.connection(provider)
            clientID = provider == .cursor ? connection.memberEmail ?? "":connection.username ?? ""
        }
        .task(id:refreshKey) {
            await runtime.refresh(kind:kind,config:config,explicit:false)
            guard config["autoRefresh"] != "false" else { return }
            let rawMinutes = Double(config["refreshMinutes"] ?? "5") ?? 5
            let minutes = rawMinutes.isFinite ? max(1,min(60,rawMinutes)):5
            while !Task.isCancelled { do { try await Task.sleep(nanoseconds:UInt64((business ? max(5,minutes):stock ? minutes:1) * 60 * 1_000_000_000)) } catch { return }; guard !Task.isCancelled else { return }; await runtime.refresh(kind:kind,config:config,explicit:false) }
        }
        .contextMenu { Button("自定义小组件…") { setup = true; presented = true }; Button("刷新") { Task { await runtime.refresh(kind:kind,config:config,explicit:true) } } }
        .onDisappear { if coordinator.activeID == item.id { coordinator.activeID = nil } }
    }
    private func displayPercent(_ value:AIAllowance)->Double {
        let raw = config["usageDisplay"] == "used" ? value.usedPercent:100 - value.usedPercent
        return raw.isFinite ? min(100,max(0,raw)):0
    }
    private func total(_ values:[Int64])->Int64 { values.reduce(0) { sum,value in let result = sum.addingReportingOverflow(max(0,value)); return result.overflow ? Int64.max:result.partialValue } }
    private var tileLimits:[(AIProvider,AIAllowance)] { Array(providers.compactMap { provider in runtime.ai[provider].flatMap(chosenLimit).map { (provider,$0) } }.prefix(3)) }
    private var limitTile:some View {
        HStack(spacing:7) { ForEach(tileLimits,id:\.0) { provider,value in
            let percent = displayPercent(value)
            VStack(spacing:3) {
                if config["aiStyle"] == "rings" {
                    ZStack { Circle().stroke(.secondary.opacity(0.15),lineWidth:3); Circle().trim(from:0,to:percent / 100).stroke(accent,style:StrokeStyle(lineWidth:3,lineCap:.round)).rotationEffect(.degrees(-90)); Text("\(Int(percent))").font(.system(size:9,weight:.semibold,design:.monospaced)) }.frame(width:29,height:29)
                } else {
                    Text("\(Int(percent))%").font(.system(size:12,weight:.semibold,design:.monospaced))
                    if config["aiStyle"] != "numbers" { ProgressView(value:percent,total:100).tint(accent).frame(width:31) }
                }
                Text(provider == .antigravity ? "AGY":provider == .copilot ? "Copilot":provider.title).font(.system(size:8)).lineLimit(1).minimumScaleFactor(0.7)
            }.frame(maxWidth:.infinity)
        } }
    }
    private func chartActivity(_ records:[AIActivityRecord])->[AIActivityRecord] {
        let interval = (period == .today ? IntegrationPeriod.l7:period).interval()
        return records.filter { interval.contains($0.date) && $0.tokenCoverage != "unavailable" }
    }
    private var activityTile:some View {
        let points = BusinessAdapters.daily(chartActivity(providers.flatMap { runtime.ai[$0]?.activity ?? [] }).map { IntegrationPoint(date:$0.date,value:Double($0.tokens)) },timeZone:.current)
        return VStack(alignment:.leading,spacing:3) {
            Text(summary).font(.system(size:10,weight:.semibold)).lineLimit(1)
            Chart(points) { point in
                if config["activityStyle"] == "sparkline" { LineMark(x:.value("日期",point.date),y:.value("Tokens",point.value)).foregroundStyle(accent) }
                else { BarMark(x:.value("日期",point.date,unit:.day),y:.value("Tokens",point.value)).foregroundStyle(accent) }
            }.chartXAxis(.hidden).chartYAxis(.hidden).frame(height:25)
        }
    }
    private var popover:some View {
        VStack(spacing:0) {
            WidgetPopoverHeader(title:title,symbol:kind.symbol,tint:accent,subtitle:setup ? "自定义与连接":kind.category,onClose:{presented = false}) {
                WidgetPopoverIconButton(symbol:"arrow.clockwise",label:"刷新") { Task { await runtime.refresh(kind:kind,config:config,explicit:true) } }.disabled(runtime.busy)
                WidgetPopoverIconButton(symbol:setup ? "chart.xyaxis.line":"gearshape",label:setup ? "查看数据":"自定义组件",prominent:setup) { setup.toggle() }
            }.padding(.bottom,12)
            ScrollView {
                VStack(alignment:.leading,spacing:16) {
                    if setup { setupView }
                    else if business { businessView }
                    else if stock { stockView }
                    else { aiView }
                    if runtime.busy { HStack { ProgressView().controlSize(.small); Text("正在刷新，保留上次成功的数据…").font(.caption).foregroundStyle(.secondary) } }
                    if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
                }.padding(16).frame(maxWidth:.infinity,alignment:.leading).dockCard(cornerRadius:16)
            }
        }.padding(14).frame(width:490,height:600).dockCard(cornerRadius:22)
            .buttonStyle(DockGlassButtonStyle()).onExitCommand { presented = false }
            .background { Button("关闭小组件") { presented = false }.keyboardShortcut("w",modifiers:.command).frame(width:0,height:0).opacity(0).accessibilityHidden(true) }
    }
    @ViewBuilder private var setupView:some View {
        TextField("组件名称",text:configBinding("title",default:title)).textFieldStyle(.roundedBorder)
        Toggle("自动刷新",isOn:boolBinding("autoRefresh",default:true))
        Picker("刷新间隔",selection:configBinding("refreshMinutes",default:"5")) { ForEach(["1","5","15","30","60"],id:\.self) { Text($0 + " 分钟").tag($0) } }
        if business { businessSetup }
        else if stock { stockSetup }
        else { aiSetup }
    }
    private var metrics:[String] { kind == .shopify ? ["revenue","orders","aov"]:kind == .paddle ? ["net","mrr","arr","paying"]:["revenue","net","mrr","arr","paying","arpu"] }
    private func metricName(_ key:String)->String { ["revenue":"订单 / 收入","net":"交易净额","mrr":"MRR","arr":"ARR","paying":"付费订阅客户","arpu":"ARPU","orders":"订单数","aov":"平均订单金额"][key] ?? key }
    private var businessView:some View {
        VStack(alignment:.leading,spacing:14) {
            accountPicker
            HStack { Picker("指标",selection:configBinding("metric",default:metric)) { ForEach(metrics,id:\.self) { Text(metricName($0)).tag($0) } }; periodPicker }
            if let report = runtime.business,let currency {
                if report.currencies.count > 1 { Picker("币种",selection:configBinding("currency",default:currency.currency)) { ForEach(report.currencies,id:\.currency) { Text($0.currency).tag($0.currency) } } }
                Text(["orders","paying"].contains(metric) ? currency.values[metric].map { NSDecimalNumber(decimal:$0).stringValue } ?? "—":IntegrationNumber.money(currency.values[metric],currency:currency.currency)).font(.system(size:32,weight:.semibold,design:.rounded))
                if let points = currency.series[metric],!points.isEmpty { chart(points,color:accent) }
                else { Text(["mrr","arr","paying","arpu"].contains(metric) ? "订阅历史从连接后积累；不会回填无法确认的历史。":"此范围没有可绘制的记录。").font(.caption).foregroundStyle(.secondary) }
                Text(report.note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Text("更新于 " + report.fetchedAt.formatted(date:.abbreviated,time:.shortened)).font(.caption2).foregroundStyle(.secondary)
                if kind == .shopify { breakdown("商品剩余数量",values:currency.products); breakdown("订单来源",values:currency.channels) }
            } else { Button("连接 \(kind.title)…") { setup = true }.buttonStyle(DockGlassButtonStyle(prominent:true)) }
            if let error = runtime.errors["business"] { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }
    private var accountPicker:some View {
        Picker("账号",selection:configBinding("accountID",default:"")) { Text("选择账号").tag(""); ForEach(IntegrationDisk.accounts.filter { $0.kind == kind.rawValue }) { Text($0.name + ($0.sandbox ? " · Sandbox":"")).tag($0.id.uuidString) } }
    }
    private var periodPicker:some View { Picker("期间",selection:configBinding("period",default:"today")) { ForEach(IntegrationPeriod.allCases) { Text($0.title).tag($0.rawValue) } } }
    private var businessSetup:some View {
        VStack(alignment:.leading,spacing:12) {
            accountPicker
            if let account = IntegrationDisk.accounts.first(where:{$0.id.uuidString == config["accountID"]}) {
                TextField("已连接账号名称",text:Binding(get:{selectedAccount?.name ?? account.name},set:{ renameAccount(account,name:$0) })).textFieldStyle(.roundedBorder)
                Picker("账号颜色",selection:Binding(get:{selectedAccount?.colorHex ?? "649FC6"},set:{ value in var updated = selectedAccount ?? account; updated.colorHex = value; saveAccount(updated) })) { ForEach(["649FC6","6FA78C","BF94CA","DBAD64","D68182"],id:\.self) { hex in Text(hex).tag(hex) } }
                Button("断开「\(account.name)」",role:.destructive) { do { try IntegrationKeychain.remove(account:account.id.uuidString); try IntegrationDisk.removeAccount(account); set("accountID",""); status = "已删除此账号的本机连接。" } catch { status = error.localizedDescription } }
            }
            Text("添加账号").font(.headline)
            Picker("新账号颜色",selection:configBinding("draftAccountColor",default:"649FC6")) { ForEach(["649FC6","6FA78C","BF94CA","DBAD64","D68182"],id:\.self) { Text($0).tag($0) } }
            TextField("账号名称",text:$accountName).textFieldStyle(.roundedBorder).onChange(of:accountName) { set("draftAccountName",$0) }
            if kind == .shopify {
                TextField("store.myshopify.com",text:$domain).textFieldStyle(.roundedBorder).onChange(of:domain) { set("draftDomain",$0) }
                TextField("Client ID",text:$clientID).textFieldStyle(.roundedBorder)
                SecureField("Client secret",text:$secret).textFieldStyle(.roundedBorder)
                Text("应用属于店铺同一组织；已发布并安装，权限 read_orders。密钥仅存储在钥匙串。").font(.caption).foregroundStyle(.secondary)
            } else {
                SecureField(kind == .stripe ? "rk_live_ / rk_test_":"Paddle API key",text:$secret).textFieldStyle(.roundedBorder)
                if kind == .paddle { Toggle("Sandbox",isOn:boolBinding("sandbox",default:false)) }
                Text(kind == .stripe ? "Restricted key：Balance + Subscriptions 仅 Read；不需要完整 secret key。":"Paddle Billing API key：metrics.read。环境须与密钥前缀一致。").font(.caption).foregroundStyle(.secondary)
            }
            HStack { Button(connecting ? "正在验证…":"验证并连接") { Task { await connectBusiness() } }.buttonStyle(DockGlassButtonStyle(prominent:true)).disabled(secret.isEmpty || connecting); if connecting { ProgressView().controlSize(.small) } }
        }.onAppear { accountName = config["draftAccountName"] ?? ""; domain = config["draftDomain"] ?? "" }
    }
    private func renameAccount(_ account:IntegrationAccount,name:String) { var updated = selectedAccount ?? account; updated.name = String(name.prefix(120)); saveAccount(updated) }
    private func saveAccount(_ account:IntegrationAccount) { do { try IntegrationDisk.saveAccount(account); set("accountRevision",UUID().uuidString) } catch { status = error.localizedDescription } }
    private func connectBusiness() async {
        connecting = true; defer { connecting = false }
        do {
            let account = IntegrationAccount(kind:kind.rawValue,name:accountName.isEmpty ? kind.title:accountName,domain:domain.trimmingCharacters(in:.whitespacesAndNewlines).lowercased(),sandbox:config["sandbox"] == "true",colorHex:config["draftAccountColor"] ?? "649FC6")
            let credentials = kind == .shopify ? ["clientID":clientID,"secret":secret]:["key":secret]
            let report = try await BusinessAdapters.load(account:account,credentials:credentials,period:period)
            try IntegrationKeychain.save(credentials,account:account.id.uuidString)
            do { try IntegrationDisk.saveAccount(account) } catch { try? IntegrationKeychain.remove(account:account.id.uuidString); throw error }
            set("accountID",account.id.uuidString); runtime.business = report; secret = ""; clientID = ""; status = "已连接，密钥保存在钥匙串。"; setup = false
        } catch { status = error.localizedDescription }
    }
    private var stockView:some View {
        VStack(alignment:.leading,spacing:14) {
            if symbols.isEmpty { stockSetup }
            else {
                stockTabs
                Picker("图表范围",selection:configBinding("range",default:"1mo")) { ForEach(StockAdapters.ranges,id:\.self) { Text($0.uppercased()).tag($0) } }
                if let report = selectedStock {
                    if let url = yahooURL(report.symbol) {
                        Link(destination:url) { HStack(spacing:6) { Text(stockName(report)).font(.headline); Image(systemName:"arrow.up.right").font(.caption) } }
                            .buttonStyle(.plain).help("在 Yahoo Finance 打开 " + report.symbol).accessibilityLabel(stockName(report) + "，在 Yahoo Finance 打开")
                    } else { Text(stockName(report)).font(.headline) }
                    Text(report.current.map { $0.formatted(.number.precision(.fractionLength(2))) + " " + report.currency } ?? "—").font(.system(size:30,weight:.semibold))
                    if config["compare"] == "true",runtime.stocks.count > 1 { Text("多股票相对变化").font(.caption.weight(.semibold)); comparisonChart }
                    StockHistoryChart(report:report,dither:config["dither"] == "true",showVolume:config["showVolume"] != "false")
                        .id(report.symbol + "|" + report.range + "|" + report.source)
                    Text(report.note + (report.points.count > 500 ? " 图表按整个范围抽样，原始数据保持完整。":"")).font(.caption).foregroundStyle(.secondary)
                    Text("\(report.source) · 更新于 \(report.fetchedAt.formatted(date:.abbreviated,time:.shortened))").font(.caption2).foregroundStyle(.secondary)
                }
                if let error = runtime.errors[config["selectedSymbol"] ?? symbols.first ?? ""] { Text(error).font(.caption).foregroundStyle(.orange) }
            }
        }
    }
    private var stockSetup:some View {
        VStack(alignment:.leading,spacing:12) {
            HStack { TextField("搜索股票 / 交易代码",text:$query).textFieldStyle(.roundedBorder).onChange(of:query) { set("draftStockSearch",$0) }; Button("搜索") { Task { await searchStock() } } }
            ForEach(matches) { match in Button { addSymbol(match.symbol); matches = [] } label: { HStack { Text(match.symbol).fontWeight(.semibold); Text(match.name).foregroundStyle(.secondary); Spacer(); Image(systemName:"plus") } }.buttonStyle(.plain) }
            ForEach(symbols,id:\.self) { code in HStack { Text(code).font(.caption.weight(.semibold)).frame(width:65,alignment:.leading); TextField("显示名称",text:configBinding("stockName-" + code,default:runtime.stocks[code]?.name ?? code)).textFieldStyle(.roundedBorder); Button { let remaining = symbols.filter { $0 != code }; set("symbols",remaining.joined(separator:",")); if config["selectedSymbol"] == code { set("selectedSymbol",remaining.first ?? "") } } label: { Image(systemName:"minus.circle").frame(width:24,height:24) }.buttonStyle(.plain).help("移除 " + code) } }
            Picker("行情来源",selection:configBinding("stockProvider",default:"yahoo")) { Text("Yahoo Finance 公开数据").tag("yahoo"); Text("Alpha Vantage").tag("alpha") }
            if config["stockProvider"] == "alpha" {
                SecureField("Alpha Vantage API key",text:$secret).textFieldStyle(.roundedBorder)
                Button("保存到钥匙串") { do { try IntegrationKeychain.save(["key":secret],account:"stock-alpha"); secret = ""; status = "已保存。" } catch { status = error.localizedDescription } }.disabled(secret.isEmpty)
            }
            Toggle("成交量",isOn:boolBinding("showVolume",default:true))
            Toggle("比较所有股票的区间涨跌",isOn:boolBinding("compare",default:false))
            Toggle("点线图",isOn:boolBinding("dither",default:false))
            Text("Yahoo 数据端点没有稳定 API 保证；Alpha Vantage 按你账号的计划与配额提供数据。行情可能延迟。").font(.caption).foregroundStyle(.secondary)
        }.onAppear { query = config["draftStockSearch"] ?? "" }
    }
    private func searchStock() async {
        do { let key = try IntegrationKeychain.read(account:"stock-alpha",allowPrompt:true)?["key"]; matches = try await StockAdapters.search(query,provider:config["stockProvider"] ?? "yahoo",key:key).map { StockMatch(symbol:$0.0,name:$0.1) }; if matches.isEmpty { status = "没有匹配结果。" } }
        catch { status = error.localizedDescription }
    }
    @ViewBuilder private var stockTabs:some View {
        if symbols.count <= 4 { HStack(spacing:8) { ForEach(symbols,id:\.self) { stockTab($0) } } }
        else { ScrollView(.horizontal,showsIndicators:false) { HStack(spacing:8) { ForEach(symbols,id:\.self) { stockTab($0).frame(width:106) } }.padding(.vertical,2) } }
    }
    private func stockTab(_ symbol:String)->some View {
        let selected = (selectedStock?.symbol ?? config["selectedSymbol"] ?? symbols.first ?? "") == symbol
        return Button { set("selectedSymbol",symbol) } label: {
            VStack(alignment:.leading,spacing:3) {
                HStack { Text(symbol).font(.system(size:12,weight:.semibold)).lineLimit(1); Spacer(minLength:0); if selected { Image(systemName:"checkmark").font(.system(size:9,weight:.semibold)) } }
                Text(runtime.stocks[symbol]?.current?.formatted(.number.precision(.fractionLength(2))) ?? "尚未读取").font(.caption2).opacity(0.8).lineLimit(1)
            }.padding(.horizontal,12).padding(.vertical,9).frame(maxWidth:.infinity,alignment:.leading)
                .foregroundStyle(selected ? Color.white:DockTheme.ink).dockGlass(cornerRadius:12,tint:selected ? DockTheme.accent:nil,interactive:true)
        }.buttonStyle(.plain).accessibilityLabel("选择股票 " + symbol).accessibilityValue(selected ? "已选中":"")
    }
    private func stockName(_ report:StockReport)->String { config["stockName-" + report.symbol]?.trimmingCharacters(in:.whitespacesAndNewlines).nonempty ?? report.name }
    private func yahooURL(_ symbol:String)->URL? {
        guard StockAdapters.validSymbol(symbol) else { return nil }
        var components = URLComponents(); components.scheme = "https"; components.host = "finance.yahoo.com"; components.path = "/quote/" + symbol + "/"
        return components.url
    }
    private func addSymbol(_ symbol:String) {
        var selected = kind == .stock ? []:symbols
        if !selected.contains(symbol),selected.count < 20 { selected.append(symbol) }
        set("symbols",selected.joined(separator:",")); set("selectedSymbol",symbol); setup = false
    }
    private var shownProviders:[AIProvider] { config["showAllProviders"] == "true" ? (kind == .aiActivity ? AIProvider.allCases.filter(\.supportsActivity):AIProvider.allCases):providers }
    private var aiView:some View {
        VStack(alignment:.leading,spacing:16) {
            if kind == .aiActivity { periodPicker }
            ForEach(shownProviders) { provider in
                VStack(alignment:.leading,spacing:10) {
                    HStack { Text(provider.title).font(.headline); Spacer(); Button("连接 / 设置") { aiProvider = provider; setup = true }.font(.caption) }
                    if let report = runtime.ai[provider] {
                        if kind == .aiLimits {
                            ForEach(report.allowances.filter { config["visible-" + provider.rawValue + "-" + $0.id] != "false" }) { allowance in allowanceView(allowance) }
                            if report.allowances.isEmpty { Text(report.reportedRequests.map { "服务报告 " + (report.reportedUnit ?? "requests") + "：" + $0.formatted() + "；供应商未返回包含额度。" } ?? "此来源没有返回订阅额度。" ).font(.caption).foregroundStyle(.secondary) }
                        } else { activityView(report) }
                        Text(report.note).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                        Text("更新于 " + report.updatedAt.formatted(date:.abbreviated,time:.shortened)).font(.caption2).foregroundStyle(.secondary)
                    } else { Text("尚未连接可读取的来源。" ).font(.caption).foregroundStyle(.secondary) }
                    if let error = runtime.errors[provider.rawValue], error != IntegrationError.noData.localizedDescription { Text(error).font(.caption).foregroundStyle(.orange) }
                }.padding(14).background(.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:12))
            }
            if providers.isEmpty { Button("选择 AI 服务") { setup = true }.buttonStyle(DockGlassButtonStyle(prominent:true)) }
        }
    }
    private func chosenLimit(_ report:AIReport)->AIAllowance? { report.allowances.first(where:{$0.id == config["limit-" + report.provider.rawValue]}) ?? report.allowances.first }
    private func allowanceView(_ value:AIAllowance)->some View {
        let percent = displayPercent(value)
        return HStack(spacing:12) {
            if config["aiStyle"] == "rings" { ZStack { Circle().stroke(.secondary.opacity(0.15),lineWidth:4); Circle().trim(from:0,to:max(0,min(1,percent/100))).stroke(DockTheme.accent,style:StrokeStyle(lineWidth:4,lineCap:.round)).rotationEffect(.degrees(-90)); Text("\(Int(percent))").font(.caption2.monospacedDigit()) }.frame(width:40,height:40) }
            VStack(alignment:.leading,spacing:5) { HStack { Text(value.title).font(.caption); Spacer(); Text("\(Int(percent))% " + (config["usageDisplay"] == "used" ? "已用":"剩余")).font(.caption.monospacedDigit()) }; if config["aiStyle"] != "numbers" { ProgressView(value:percent,total:100).tint(DockTheme.accent) }; if let reset = value.resetsAt { Text(reset > .now ? "重置 " + reset.formatted(date:.abbreviated,time:.shortened):"重置时间已过，等待供应商新数据").font(.caption2).foregroundStyle(.secondary) } }
        }
    }
    private func activityTokensLabel(_ records:[AIActivityRecord],tokens:Int64)->String {
        if !records.isEmpty,records.allSatisfy({ $0.tokenCoverage == "unavailable" }) { return "Tokens 未报告" }
        var prefix = ""
        if records.contains(where: \.estimated) { prefix = "≈ " }
        else if records.contains(where:{ ["partial","unavailable"].contains($0.tokenCoverage ?? "") }) { prefix = "≥ " }
        return prefix + tokens.formatted() + " tokens"
    }
    private func cursorActivityCaption(_ records:[AIActivityRecord])->String {
        let requests = records.reduce(0.0) { $0 + $1.requests }
        let costs = records.compactMap(\.costUSD)
        let requestText:String
        if records.allSatisfy({ $0.requestsReported == false }) { requestText = "请求单位未报告" }
        else { requestText = (records.contains(where:{ $0.requestsReported == false }) ? "≥ ":"") + requests.formatted() + " 报告请求单位" }
        let costText:String
        if costs.isEmpty { costText = "费用未报告" }
        else { costText = (records.contains(where:{ $0.costUSD == nil }) ? "≥ ":"") + costs.reduce(0,+).formatted(.currency(code:"USD")) + " 供应商报告费用" }
        return requestText + " · " + costText
    }
    @ViewBuilder private func activityPlot(_ points:[IntegrationPoint])->some View {
        if !points.isEmpty,config["activityStyle"] != "totals" {
            Chart(points) { point in
                if config["activityStyle"] == "sparkline" { LineMark(x:.value("日期",point.date),y:.value("Tokens",point.value)).foregroundStyle(DockTheme.accent) }
                else { BarMark(x:.value("日期",point.date,unit:.day),y:.value("Tokens",point.value)).foregroundStyle(DockTheme.accent) }
            }.frame(height:100)
            if period == .today { Text("近 7 天趋势；上方总数仅为今天").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func activityView(_ report:AIReport)->some View {
        let records = report.activity.filter { period.interval().contains($0.date) }
        let tokens = total(records.map(\.tokens)),cached = total(records.map(\.cached)),tools = total(records.map(\.tools))
        let sessions = Set(records.map(\.session).filter { !$0.isEmpty }).count
        let points = BusinessAdapters.daily(chartActivity(report.activity).map { IntegrationPoint(date:$0.date,value:Double($0.tokens)) },timeZone:.current)
        let label = activityTokensLabel(records,tokens:tokens)
        let caption = report.provider == .cursor ? cursorActivityCaption(records):"缓存 \(cached.formatted()) · 工具调用 \(tools.formatted())"
        return VStack(alignment:.leading,spacing:10) {
            HStack { Text(label).font(.title3.monospacedDigit()); Spacer(); if sessions > 0 { Text("\(sessions) 会话").font(.caption) } }
            activityPlot(points)
            if report.provider != .grok { Text(caption).font(.caption) }
            if records.isEmpty { Text("此范围没有可读取的活动，不代表账号总用量为零。").font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func toggleProvider(_ provider:AIProvider,enabled:Bool) {
        var selected = providers
        if enabled { if !selected.contains(provider) { selected.append(provider) } }
        else {
            selected.removeAll { $0 == provider }
            if provider == .claude { Task { await ClaudeDesktopUsage.shared.disconnect(); claudeDesktopConnected = false } }
            if [.claude,.antigravity].contains(provider) { do { if try !IntegrationStatusBridge.disconnect(provider) { status = "CLI 状态栏命令已改动，保留现有设置。" } } catch { status = error.localizedDescription } }
        }
        set("providers",selected.map(\.rawValue).joined(separator:","))
    }
    private var aiSetup:some View {
        VStack(alignment:.leading,spacing:14) {
            Toggle("弹窗显示所有服务",isOn:boolBinding("showAllProviders",default:false))
            if kind == .aiActivity { Picker("活动样式",selection:configBinding("activityStyle",default:"bars")) { Text("柱状").tag("bars"); Text("趋势").tag("sparkline"); Text("总数").tag("totals") }.pickerStyle(.segmented) }
            Text("服务与顺序").font(.headline)
            ForEach(kind == .aiActivity ? AIProvider.allCases.filter(\.supportsActivity):AIProvider.allCases) { provider in
                HStack { Toggle(provider.title,isOn:Binding(get:{providers.contains(provider)},set:{ toggleProvider(provider,enabled:$0) })); Spacer(); if let index = providers.firstIndex(of:provider),index > 0 { Button { var selected = providers; selected.swapAt(index,index - 1); set("providers",selected.map(\.rawValue).joined(separator:",")) } label: { Image(systemName:"arrow.up") }.buttonStyle(.plain) } }
            }
            Picker("显示",selection:configBinding("aiStyle",default:"bars")) { Text("条形").tag("bars"); Text("圆环").tag("rings"); Text("数字").tag("numbers") }.pickerStyle(.segmented)
            Picker("额度",selection:configBinding("usageDisplay",default:"remaining")) { Text("剩余").tag("remaining"); Text("已用").tag("used") }.pickerStyle(.segmented)
            Divider()
            Picker("连接服务",selection:$aiProvider) { ForEach(AIProvider.allCases) { Text($0.title).tag($0) } }
            Text(aiProvider.instructions).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            if let report = runtime.ai[aiProvider],!report.allowances.isEmpty { Picker("Dock 首选额度",selection:configBinding("limit-" + aiProvider.rawValue,default:report.allowances.first!.id)) { ForEach(report.allowances) { Text($0.title).tag($0.id) } } }
            if let report = runtime.ai[aiProvider],kind == .aiLimits { ForEach(report.allowances) { allowance in Toggle("弹窗显示 " + allowance.title,isOn:boolBinding("visible-" + aiProvider.rawValue + "-" + allowance.id,default:true)) } }
            if [.gemini,.grok,.cursor].contains(aiProvider) { Button("选择现有登录文件并连接…") { connectExistingLogin() }; if AIAdapters.connection(aiProvider).existingLogin == true { Button("停止读取现有登录") { disconnectExistingLogin() } } }
            if aiProvider == .gemini { TextField("Google 项目 ID（可选）",text:Binding(get:{AIAdapters.connection(.gemini).quotaProject ?? ""},set:{ value in do { var connection = AIAdapters.connection(.gemini); connection.quotaProject = value; try AIAdapters.saveConnection(connection,provider:.gemini) } catch { status = error.localizedDescription } })).textFieldStyle(.roundedBorder) }
            if aiProvider == .copilot { Button("选择已登录的 Copilot CLI 并连接…") { connectCopilotCLI() }; Button("选择已登录的 GitHub CLI 并连接…") { connectGitHubCLI() }; if AIAdapters.connection(.copilot).existingLogin == true { Button("停止读取 GitHub 登录") { disconnectExistingLogin() } } }
            if [.codex,.claude,.grok].contains(aiProvider) { Button("选择本地活动文件夹…") { connectFolder() } }
            if aiProvider == .codex { HStack { Button("连接本机 Codex") { connectDetectedCodex() }; Button("选择 Codex CLI…") { connectCLI() } } }
            if [.claude,.antigravity].contains(aiProvider) {
                if IntegrationStatusBridge.installed(aiProvider) { Button("断开状态栏连接") { do { status = try IntegrationStatusBridge.disconnect(aiProvider) ? "已恢复原始状态栏命令。":"CLI 命令已被手动更改，已保留设置与恢复副本。" } catch { status = error.localizedDescription } } }
                else { Button("连接 CLI 状态栏") { do { try IntegrationStatusBridge.connect(aiProvider); status = "已连接。请重启对应 CLI，再发送消息或运行 /usage。" } catch { status = error.localizedDescription } } }
            }
            if aiProvider == .claude {
                Button("连接 Claude Desktop…") { connectClaudeDesktop() }.disabled(connecting)
                if claudeDesktopConnected || ClaudeDesktopUsage.selectedCookieDatabase != nil { Button("停止 Desktop 读取") { Task { await ClaudeDesktopUsage.shared.disconnect(); claudeDesktopConnected = false; runtime.ai[.claude] = nil; status = "已停止 Desktop 读取，Claude 保持登录。" } } }
                Text("显式连接或刷新可能请求 Claude Safe Storage 钥匙串授权。后台只使用本次连接的内存会话，重启后需刷新授权；接口受版本和组织权限影响。").font(.caption2).foregroundStyle(.secondary)
            }
            if [.cursor,.copilot].contains(aiProvider) {
                TextField(aiProvider == .cursor ? "成员邮箱（可选）":"GitHub 用户名",text:$clientID).textFieldStyle(.roundedBorder)
                SecureField(aiProvider == .cursor ? "Cursor Admin API key":"GitHub Plan(read) token",text:$secret).textFieldStyle(.roundedBorder)
                Button("连接 API") { connectAIAPI() }.disabled(secret.isEmpty)
            }
            Button("导入供应商数值报告…") { importAIReport() }
            Text("账号连接由所有 AI 组件共享。仅保存数值、重置时间与更新时间；不保存对话、提示词或工具参数。").font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func connectClaudeDesktop() {
        let panel = NSOpenPanel(); panel.title = "选择 Claude Desktop Cookies 数据库"; panel.showsHiddenFiles = true; panel.prompt = "允许读取并连接"; panel.message = "读取 Claude Desktop 的现有会话，仅向 claude.ai 查询五小时/每周额度。可能请求 Claude Safe Storage 钥匙串权限，不修改登录或保存 cookie。"
        let url = ClaudeDesktopUsage.defaultCookieLocations().first ?? FileManager.default.homeDirectoryForCurrentUser
        panel.directoryURL = url.deletingLastPathComponent(); panel.nameFieldStringValue = url.lastPathComponent
        guard panel.runModal() == .OK,let selected = panel.url else { return }
        connecting = true
        Task { defer { connecting = false }; do { let report = try await ClaudeDesktopUsage.shared.connect(cookieDatabase:selected); runtime.ai[.claude] = report; claudeDesktopConnected = true; status = "已连接 Claude Desktop；后台刷新不会请求授权。" } catch { status = error.localizedDescription } }
    }
    private func connectExistingLogin() {
        let panel = NSOpenPanel(); panel.title = "选择 \(aiProvider.title) 的现有登录文件"; panel.showsHiddenFiles = true; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.message = "连接后允许 OpenDock 只读此文件中的现有登录，向对应供应商查询额度。不会复制、刷新或修改登录凭据。"
        panel.prompt = "允许读取并连接"
        let defaults:[AIProvider:String] = [.gemini:".gemini/oauth_creds.json",.grok:".grok/auth.json",.cursor:"Library/Application Support/Cursor/User/globalStorage/state.vscdb"]
        if let path = defaults[aiProvider] { let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path); panel.directoryURL = url.deletingLastPathComponent(); panel.nameFieldStringValue = url.lastPathComponent }
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { var connection = AIAdapters.connection(aiProvider); connection.authFile = url.path; connection.existingLogin = true; try AIAdapters.saveConnection(connection,provider:aiProvider); status = "已连接现有登录，只读查询额度。"; Task { await runtime.refresh(kind:kind,config:config,explicit:true) } } catch { status = error.localizedDescription }
    }
    private func disconnectExistingLogin() {
        do { var connection = AIAdapters.connection(aiProvider); connection.existingLogin = false; connection.authFile = nil; connection.copilotExecutable = nil; connection.executable = nil; try AIAdapters.saveConnection(connection,provider:aiProvider); IntegrationDisk.remove(key:"ai-cache-" + aiProvider.rawValue); runtime.ai[aiProvider] = nil; status = "已停止读取；供应商账号保持登录。" } catch { status = error.localizedDescription }
    }
    private func connectCopilotCLI() {
        let panel = NSOpenPanel(); panel.title = "选择已登录的 Copilot CLI"; panel.prompt = "允许查询并连接"; panel.message = "通过官方 SDK 的 account.getQuota 查询账号额度；不创建模型会话，不消耗模型额度。"; panel.directoryURL = URL(fileURLWithPath:"/opt/homebrew/bin")
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { guard FileManager.default.isExecutableFile(atPath:url.path) else { throw IntegrationError.invalid("请选择可执行文件。") }; var connection = AIAdapters.connection(.copilot); connection.copilotExecutable = url.path; connection.existingLogin = true; try AIAdapters.saveConnection(connection,provider:.copilot); status = "已连接 Copilot CLI。"; Task { await runtime.refresh(kind:kind,config:config,explicit:true) } } catch { status = error.localizedDescription }
    }
    private func connectGitHubCLI() {
        let panel = NSOpenPanel(); panel.title = "选择已通过 gh auth login 登录的 gh"; panel.prompt = "允许查询并连接"; panel.message = "OpenDock 只通过 gh api 查询 github.com 的 Copilot 额度，不读取或保存 GitHub token。"
        panel.directoryURL = URL(fileURLWithPath:"/opt/homebrew/bin")
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { var connection = AIAdapters.connection(.copilot); connection.executable = url.path; connection.existingLogin = true; try AIAdapters.saveConnection(connection,provider:.copilot); status = "已连接 GitHub CLI。"; Task { await runtime.refresh(kind:kind,config:config,explicit:true) } } catch { status = error.localizedDescription }
    }
    private func connectDetectedCodex() {
        let paths = ["/Applications/Codex.app/Contents/Resources/codex","/opt/homebrew/bin/codex","/usr/local/bin/codex"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath:$0) }) else { status = "没有找到 Codex，请使用选择 CLI 手动指定。"; return }
        do { var connection = AIAdapters.connection(.codex); connection.executable = path; let sessions = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions"); if FileManager.default.fileExists(atPath:sessions.path) { connection.folder = sessions.path }; try AIAdapters.saveConnection(connection,provider:.codex); status = "已连接已有的 Codex 登录和本机数值日志。"; Task { await runtime.refresh(kind:kind,config:config,explicit:true) } } catch { status = error.localizedDescription }
    }
    private func connectFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.title = "选择 \(aiProvider.title) 的本地活动日志文件夹"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { var connection = AIAdapters.connection(aiProvider); connection.folder = url.path; try AIAdapters.saveConnection(connection,provider:aiProvider); status = "已连接本地日志；只读取数值字段。"; Task { await runtime.refresh(kind:kind,config:config,explicit:true) } } catch { status = error.localizedDescription }
    }
    private func connectCLI() {
        let panel = NSOpenPanel(); panel.title = "选择 Codex CLI 可执行文件"; panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.showsHiddenFiles = true
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { guard FileManager.default.isExecutableFile(atPath:url.path) else { throw IntegrationError.invalid("该文件不可执行。") }; var connection = AIAdapters.connection(.codex); connection.executable = url.path; try AIAdapters.saveConnection(connection,provider:.codex); status = "已连接；额度查询不会创建模型任务。"; Task { await runtime.refresh(kind:kind,config:config,explicit:true) } } catch { status = error.localizedDescription }
    }
    private func connectAIAPI() {
        do { var connection = AIAdapters.connection(aiProvider); if aiProvider == .cursor { connection.memberEmail = clientID } else { connection.username = clientID }; try IntegrationKeychain.save(["key":secret],account:"ai-" + aiProvider.rawValue); try AIAdapters.saveConnection(connection,provider:aiProvider); secret = ""; status = "API 凭据已存入钥匙串。"; Task { await runtime.refresh(kind:kind,config:config,explicit:true) } } catch { status = error.localizedDescription }
    }
    private func importAIReport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.title = "导入 \(aiProvider.title) 数值报告"
        guard panel.runModal() == .OK,let url = panel.url else { return }
        do { let report = try AIAdapters.imported(Data(contentsOf:url),provider:aiProvider); var connection = AIAdapters.connection(aiProvider); connection.importedReport = report; try AIAdapters.saveConnection(connection,provider:aiProvider); runtime.ai[aiProvider] = report; status = "已导入供应商报告。" } catch { status = error.localizedDescription }
    }
    private func sampled(_ points:[IntegrationPoint])->[IntegrationPoint] {
        guard points.count > 500 else { return points }; let stride = max(1,Int(ceil(Double(points.count) / 499)))
        var result = Swift.stride(from:0,to:points.count,by:stride).map { points[$0] }
        if result.last?.date != points.last?.date,let last = points.last { result.append(last) }; return result
    }
    private func chart(_ points:[IntegrationPoint],color:Color)->some View {
        Chart(sampled(points)) { point in
            if config["dither"] == "true" { PointMark(x:.value("时间",point.date),y:.value("数值",point.value)).symbolSize(8).foregroundStyle(color) }
            else { LineMark(x:.value("时间",point.date),y:.value("数值",point.value)).foregroundStyle(color) }
            if let hovered { RuleMark(x:.value("选中时间",hovered.date)).foregroundStyle(.secondary.opacity(0.5)) }
        }.frame(height:160).chartYScale(domain:.automatic(includesZero:false)).chartOverlay { proxy in GeometryReader { geometry in Rectangle().fill(.clear).contentShape(Rectangle()).onContinuousHover { phase in
            switch phase { case .active(let location): if let date:Date = proxy.value(atX:location.x - geometry[proxy.plotAreaFrame].origin.x) { hovered = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }; case .ended:hovered = nil }
        }.gesture(DragGesture(minimumDistance:0).onChanged { value in
            if let date:Date = proxy.value(atX:value.location.x - geometry[proxy.plotAreaFrame].origin.x) { hovered = points.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) } }
        }.onEnded { _ in hovered = nil }) } }
    }
    private var comparisonChart:some View {
        Chart {
            ForEach(symbols,id:\.self) { symbol in
                if let report = runtime.stocks[symbol],let initial = report.points.first?.value,initial > 0 {
                    ForEach(sampled(report.points)) { point in LineMark(x:.value("时间",point.date),y:.value("区间变化 %",(point.value/initial - 1) * 100)).foregroundStyle(by:.value("股票",symbol)) }
                }
            }
        }.frame(height:170)
    }
    private func breakdown(_ title:String,values:[String:Double])->some View { VStack(alignment:.leading,spacing:7) { if !values.isEmpty { Text(title).font(.caption.bold()); ForEach(values.sorted { $0.value > $1.value }.prefix(10),id:\.key) { entry in HStack { Text(entry.key).lineLimit(1); Spacer(); Text(entry.value.formatted()) }.font(.caption) } } } }
    private func set(_ key:String,_ value:String) { config[key] = value; var updated = item; updated.configuration = config; onUpdate(updated) }
    private func configBinding(_ key:String,default value:String)->Binding<String> { Binding(get:{config[key] ?? value},set:{set(key,$0)}) }
    private func boolBinding(_ key:String,default value:Bool)->Binding<Bool> { Binding(get:{config[key].map { $0 == "true" } ?? value},set:{set(key,String($0))}) }
}
private struct StockMatch:Identifiable { var id:String { symbol };var symbol:String;var name:String }

/// Keep chart interaction state independent from the tile's credential/configuration state.
private struct StockHistoryChart: View {
    let report: StockReport
    let dither: Bool
    let showVolume: Bool
    private let points: [IntegrationPoint]
    @State private var hovered: IntegrationPoint?
    @State private var dragAnchor: IntegrationPoint?
    @State private var selection: StockChartSelection?
    @State private var showDateControls = false

    init(report: StockReport, dither: Bool, showVolume: Bool) {
        self.report = report; self.dither = dither; self.showVolume = showVolume
        points = StockChartSelection.orderedPoints(report.points)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if points.isEmpty { Text("没有可比较的有效价格记录。").font(.caption).foregroundStyle(.secondary) }
            else {
                priceChart
                if showVolume, !volumePoints.isEmpty { volumeChart }
                hoverReadout
                comparisonReadout
                dateControls
            }
        }.onChange(of: report.points) { _ in refreshSelection() }
    }

    private var priceChart: some View {
        Chart {
            ForEach(sample(points)) { point in
                if dither { PointMark(x: .value("时间", point.date), y: .value("价格", point.value)).symbolSize(8).foregroundStyle(DockTheme.accent) }
                else { LineMark(x: .value("时间", point.date), y: .value("价格", point.value)).foregroundStyle(DockTheme.accent) }
            }
            if let selection {
                RuleMark(x: .value("起点", selection.start.date)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
                RuleMark(x: .value("终点", selection.end.date)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.secondary)
                PointMark(x: .value("起点", selection.start.date), y: .value("价格", selection.start.value)).symbolSize(38).foregroundStyle(DockTheme.accent)
                PointMark(x: .value("终点", selection.end.date), y: .value("价格", selection.end.value)).symbolSize(38).foregroundStyle(DockTheme.accent)
            }
            if let hovered {
                RuleMark(x: .value("悬停时间", hovered.date)).foregroundStyle(.secondary.opacity(0.5))
                PointMark(x: .value("悬停时间", hovered.date), y: .value("价格", hovered.value)).symbolSize(28).foregroundStyle(DockTheme.accent)
            }
        }.frame(height: 160)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartOverlay { proxy in GeometryReader { geometry in interaction(proxy, frame: geometry[proxy.plotAreaFrame]) } }
            .accessibilityLabel(report.symbol + " 价格历史")
            .accessibilityHint("可使用下方的起点、终点日期选择器比较区间。")
    }

    private func interaction(_ proxy: ChartProxy, frame: CGRect) -> some View {
        ZStack {
            if let selection, let start = proxy.position(forX: selection.start.date), let end = proxy.position(forX: selection.end.date) {
                Rectangle().fill(DockTheme.accent.opacity(0.12))
                    .frame(width: max(1, abs(end - start)), height: frame.height)
                    .position(x: frame.minX + (start + end) / 2, y: frame.midY)
                    .allowsHitTesting(false).accessibilityHidden(true)
            }
            Rectangle().fill(.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    guard dragAnchor == nil else { return }
                    switch phase {
                    case .active(let location): hovered = frame.contains(location) ? point(at: location, proxy: proxy, frame: frame) : nil
                    case .ended: hovered = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                    guard frame.contains(value.startLocation) else { return }
                    if dragAnchor == nil { dragAnchor = point(at: value.startLocation, proxy: proxy, frame: frame) }
                    guard let start = dragAnchor, let end = point(at: value.location, proxy: proxy, frame: frame) else { return }
                    selection = StockChartSelection(start: start, end: end); hovered = end
                }.onEnded { _ in dragAnchor = nil; hovered = nil })
        }
    }

    private func point(at location: CGPoint, proxy: ChartProxy, frame: CGRect) -> IntegrationPoint? {
        let x = min(frame.width, max(0, location.x - frame.minX))
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return StockChartSelection.nearestPoint(to: date, in: points)
    }

    private var volumePoints: [IntegrationPoint] { points.filter { point in guard let volume = point.volume else { return false }; return volume.isFinite && volume >= 0 } }
    private var volumeChart: some View {
        Chart(sample(volumePoints)) { point in
            BarMark(x: .value("时间", point.date), y: .value("成交量", point.volume ?? 0)).foregroundStyle(DockTheme.accent.opacity(0.35))
        }.frame(height: 70).accessibilityLabel("成交量历史")
    }

    @ViewBuilder private var hoverReadout: some View {
        if let hovered {
            Text(dateText(hovered.date) + " · " + priceText(hovered.value) + " " + report.currency)
                .font(.caption.monospacedDigit()).accessibilityLabel("悬停价格")
        } else { Text("悬停查看价格，拖动选择区间。").font(.caption).foregroundStyle(.secondary) }
    }

    @ViewBuilder private var comparisonReadout: some View {
        if let selection {
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("区间" + direction(selection.change)).font(.caption.weight(.semibold))
                    Spacer()
                    Button("清除") { self.selection = nil; hovered = nil }.buttonStyle(.plain).font(.caption)
                }
                Text(changeText(selection)).font(.system(size: 18, weight: .semibold, design: .rounded)).foregroundStyle(changeColor(selection.change))
                Text(dateText(selection.start.date) + " → " + dateText(selection.end.date)).font(.caption.monospacedDigit())
                Text("起点 " + priceText(selection.start.value) + " · 终点 " + priceText(selection.end.value) + " " + report.currency + " · " + durationText(selection.duration))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(DockTheme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityElement(children: .contain).accessibilityLabel("股票区间比较")
        }
    }

    @ViewBuilder private var dateControls: some View {
        if let first = points.first, let last = points.last {
            DisclosureGroup("用日期选择比较区间", isExpanded: $showDateControls) {
                VStack(alignment: .leading, spacing: 8) {
                    DatePicker("起点", selection: dateBinding(starting: true, first: first, last: last), in: first.date...last.date, displayedComponents: [.date, .hourAndMinute])
                    DatePicker("终点", selection: dateBinding(starting: false, first: first, last: last), in: first.date...last.date, displayedComponents: [.date, .hourAndMinute])
                    Button("比较整个范围") { selection = StockChartSelection(start: first, end: last) }.disabled(points.count < 2)
                    Text("日期吸附到最近的真实价格记录，按时间先后比较。").font(.caption2).foregroundStyle(.secondary)
                }.padding(.top, 8)
            }.font(.caption).disabled(points.count < 2)
        }
    }

    private func dateBinding(starting: Bool, first: IntegrationPoint, last: IntegrationPoint) -> Binding<Date> {
        Binding(get: { starting ? (selection?.start.date ?? first.date) : (selection?.end.date ?? last.date) }, set: { date in
            let start = starting ? date : (selection?.start.date ?? first.date)
            let end = starting ? (selection?.end.date ?? last.date) : date
            selection = StockChartSelection.comparing(points, from: start, to: end); hovered = nil
        })
    }

    private func refreshSelection() {
        if let selection { self.selection = StockChartSelection.comparing(points, from: selection.start.date, to: selection.end.date) }
        if let hovered { self.hovered = StockChartSelection.nearestPoint(to: hovered.date, in: points) }
        dragAnchor = nil
    }

    private func sample(_ values: [IntegrationPoint]) -> [IntegrationPoint] {
        guard values.count > 500 else { return values }
        let step = max(1, Int(ceil(Double(values.count) / 499)))
        var result = Swift.stride(from: 0, to: values.count, by: step).map { values[$0] }
        if result.last?.date != values.last?.date, let last = values.last { result.append(last) }
        return result
    }
    private func priceText(_ value: Double) -> String { value.formatted(.number.precision(.fractionLength(2))) }
    private func signed(_ value: Double) -> String { (value > 0 ? "+" : "") + priceText(value) }
    private func dateText(_ value: Date) -> String { value.formatted(date: .abbreviated, time: .shortened) }
    private func changeText(_ selection: StockChartSelection) -> String {
        let amount = selection.change.map(signed) ?? "变化不可计算"
        let percent = selection.percentChange.map { signed($0) + "%" } ?? "百分比不可计算"
        return amount + " " + report.currency + " · " + percent
    }
    private func direction(_ change: Double?) -> String { guard let change else { return "变化不可计算" }; return change > 0 ? "上涨" : change < 0 ? "下跌" : "持平" }
    private func changeColor(_ change: Double?) -> Color { guard let change else { return .secondary }; return change > 0 ? .green : change < 0 ? .red : .secondary }
    private func durationText(_ duration: TimeInterval) -> String {
        guard duration.isFinite else { return "跨度不可计算" }
        guard duration > 0 else { return "同一数据点" }
        let formatter = DateComponentsFormatter(); formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]; formatter.maximumUnitCount = 2
        return "跨度 " + (formatter.string(from: duration) ?? duration.formatted() + " 秒")
    }
}
private extension String { var nonempty:String? { isEmpty ? nil:self } }
