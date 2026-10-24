// TibberPrice – Preis pro Viertelstunde in der Menüleiste.
// Daten: Tibber GraphQL, priceInfo(resolution: QUARTER_HOURLY).
import SwiftUI
import Security
import ServiceManagement
import Combine

// MARK: - Modell

struct Slot: Identifiable, Equatable {
    let id: Date
    let total: Double
    let level: String
}

enum ISO {
    nonisolated(unsafe) static let frac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    nonisolated(unsafe) static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

// MARK: - Aussehen (angelehnt an die Tibber-App)

enum Palette {
    static let bg = Color(red: 0.043, green: 0.043, blue: 0.051)
    static let pill = Color(white: 0.16)
    static let cheap = Color(red: 0.30, green: 0.85, blue: 0.76)
    static let expensive = Color(red: 0.94, green: 0.55, blue: 0.16)
    static let veryExpensive = Color(red: 0.93, green: 0.36, blue: 0.16)
    static let text = Color(white: 0.95)
    static let dim = Color(white: 0.62)
    static let faint = Color(white: 0.38)
}

// Farbe nach relativer Lage im sichtbaren Zeitraum: türkis = günstig, orange/rot = teuer.
// Nicht das `level` der API nutzen: das ist bei Viertelstundenwerten inkonsistent.
func priceColor(_ t: Double) -> Color {
    let x = min(max(t, 0), 1)
    if x <= 0.40 { return Palette.cheap }
    if x <= 0.75 { return lerp(Palette.cheap, Palette.expensive, (x - 0.40) / 0.35) }
    return lerp(Palette.expensive, Palette.veryExpensive, (x - 0.75) / 0.25)
}

func lerp(_ a: Color, _ b: Color, _ t: Double) -> Color {
    guard let ca = NSColor(a).usingColorSpace(.sRGB),
          let cb = NSColor(b).usingColorSpace(.sRGB) else { return a }
    let k = CGFloat(min(max(t, 0), 1))
    return Color(.sRGB,
                 red: ca.redComponent + (cb.redComponent - ca.redComponent) * k,
                 green: ca.greenComponent + (cb.greenComponent - ca.greenComponent) * k,
                 blue: ca.blueComponent + (cb.blueComponent - ca.blueComponent) * k,
                 opacity: 1)
}

func levelLabel(_ t: Double) -> String {
    t <= 0.33 ? "günstig" : t <= 0.70 ? "normal" : "teuer"
}

func priceString(_ total: Double, _ currency: String) -> String {
    let s: String
    if currency == "EUR" {
        s = String(format: "%.1f", total * 100) + " ct"
    } else {
        s = String(format: "%.3f", total) + " " + currency
    }
    return s.replacingOccurrences(of: ".", with: ",")
}

/// Zahl ohne Einheit, für die große Anzeige im Ring.
func amountString(_ total: Double, _ currency: String) -> String {
    let v = currency == "EUR" ? total * 100 : total
    return String(format: currency == "EUR" ? "%.1f" : "%.3f", v)
        .replacingOccurrences(of: ".", with: ",")
}

func unitString(_ currency: String) -> String { currency == "EUR" ? "ct" : currency }

func pickCurrent(in slots: [Slot], at now: Date) -> Slot? {
    slots.last { $0.id <= now } ?? slots.first
}

// MARK: - API

private struct Envelope: Decodable {
    let data: Payload?
    let errors: [GQLError]?
}
private struct GQLError: Decodable { let message: String }
private struct Payload: Decodable { let viewer: Viewer }
private struct Viewer: Decodable { let homes: [Home] }
private struct Home: Decodable { let currentSubscription: Sub? }
private struct Sub: Decodable { let priceInfo: PriceInfo }
private struct PriceInfo: Decodable {
    let current: RawPrice?
    let today: [RawPrice]
    let tomorrow: [RawPrice]
}
private struct RawPrice: Decodable {
    let total: Double
    let startsAt: String
    let level: String?
    let currency: String?
}

enum AppError: LocalizedError {
    case msg(String)
    var errorDescription: String? {
        switch self { case .msg(let m): return m }
    }
}

enum GraphQL {
    static let endpoint = URL(string: "https://api.tibber.com/v1-beta/gql")!
    static let query = """
    query {
      viewer {
        homes {
          currentSubscription {
            priceInfo(resolution: QUARTER_HOURLY) {
              current { total startsAt level currency }
              today { total startsAt level currency }
              tomorrow { total startsAt level currency }
            }
          }
        }
      }
    }
    """

    static func parse(_ data: Data) throws -> (slots: [Slot], currency: String) {
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        if let e = env.errors?.first { throw AppError.msg(e.message) }
        guard let info = env.data?.viewer.homes.first?.currentSubscription?.priceInfo else {
            throw AppError.msg("Keine Preisdaten in der Antwort")
        }
        var byDate: [Date: Slot] = [:]
        for p in info.today + info.tomorrow {
            guard let d = ISO.frac.date(from: p.startsAt) ?? ISO.plain.date(from: p.startsAt) else { continue }
            byDate[d] = Slot(id: d, total: p.total, level: p.level ?? "NORMAL")
        }
        let slots = byDate.values.sorted { $0.id < $1.id }
        let currency = info.current?.currency ?? info.today.first?.currency ?? "EUR"
        return (slots, currency)
    }
}

// MARK: - Token-Ablage

// Bewusst Datei statt Keychain: Keychain-Einträge einer ad-hoc signierten App lösen
// nach jedem Build einen Passwort-Dialog aus (ACL hängt an der Signatur).
// Schutz: nur für den eigenen Benutzer lesbar (0600).
enum TokenStore {
    private static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TibberPrice", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static var url: URL { dir.appendingPathComponent("token") }

    static func load() -> String? {
        if let d = try? Data(contentsOf: url),
           let s = String(data: d, encoding: .utf8), !s.isEmpty {
            return s
        }
        // Migration aus der früheren Keychain-Ablage
        if let legacy = legacyKeychainLoad() {
            save(legacy)
            legacyKeychainDelete()
            return legacy
        }
        return nil
    }

    static func save(_ token: String) {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(token.utf8).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "de.klspn.TibberPrice",
         kSecAttrAccount as String: "tibber-token"]
    }

    private static func legacyKeychainLoad() -> String? {
        var q = base
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8), !s.isEmpty else { return nil }
        return s
    }

    private static func legacyKeychainDelete() {
        SecItemDelete(base as CFDictionary)
    }
}

// MARK: - Autostart

enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    /// nil = ok, sonst Fehlertext
    static func set(_ on: Bool) -> String? {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    @Published var slots: [Slot] = []
    @Published var currency = "EUR"
    @Published var status: String? = nil          // Fehlertext
    @Published var loading = false
    @Published var needsToken = false
    @Published var updated: Date? = nil
    @Published var selectedDay: Date? = nil
    @Published var span2 = false                  // Heute/Morgen vs. 2 Tage
    @Published var hourly = false                 // 60-Minuten-Ansicht
    @Published var now = Date()

    private var loop: Task<Void, Never>?
    private var token: String?

    /// authenticate: false nur für --preview (rendert nur den Cache).
    init(authenticate: Bool = true) {
        if authenticate {
            Task { await bootstrap() }
        } else {
            loadCache()
        }
    }

    private func bootstrap() async {
        // Token genau einmal pro Start lesen, danach nur noch aus dem Speicher.
        token = TokenStore.load()
        needsToken = token == nil
        guard !needsToken else { return }
        loadCache()
        startLoop()
        if !cacheUsable { await refresh() }
    }

    var hasToken: Bool { token != nil }

    // MARK: abgeleitet

    var currentSlot: Slot? { pickCurrent(in: slots, at: now) }

    var days: [Date] {
        Set(slots.map { Calendar.current.startOfDay(for: $0.id) }).sorted()
    }

    var activeDay: Date {
        let today = Calendar.current.startOfDay(for: now)
        if let s = selectedDay { return s }
        return days.contains(today) ? today : (days.first ?? today)
    }

    func slots(on day: Date) -> [Slot] {
        slots.filter { Calendar.current.isDate($0.id, inSameDayAs: day) }
    }

    var activeSlots: [Slot] { slots(on: activeDay) }

    /// Sichtbarer Zeitraum: ein Tag oder zwei Tage ab dem gewählten Tag.
    var visibleSlots: [Slot] {
        let start = Calendar.current.startOfDay(for: activeDay)
        guard let end = Calendar.current.date(byAdding: .day, value: span2 ? 2 : 1, to: start) else {
            return activeSlots
        }
        return slots.filter { $0.id >= start && $0.id < end }
    }

    /// Was der Chart zeichnet: 15-Minuten-Werte oder zu Stunden gemittelt.
    var chartSlots: [Slot] {
        hourly ? Store.hourly(visibleSlots) : visibleSlots
    }

    /// 0 = günstigster Slot im sichtbaren Zeitraum, 1 = teuerster.
    func position(_ value: Double) -> Double {
        let v = visibleSlots.map(\.total)
        guard let lo = v.min(), let hi = v.max(), hi > lo else { return 0.5 }
        return (value - lo) / (hi - lo)
    }

    var visibleAverage: Double {
        let v = visibleSlots
        guard !v.isEmpty else { return 0 }
        return v.map(\.total).reduce(0, +) / Double(v.count)
    }

    func isTomorrow(_ d: Date) -> Bool {
        Calendar.current.isDateInTomorrow(d)
    }

    var slotSeconds: TimeInterval {
        guard slots.count > 1 else { return 900 }
        return slots[1].id.timeIntervalSince(slots[0].id)
    }

    func dayLabel(_ d: Date) -> String {
        let today = Calendar.current.startOfDay(for: now)
        if d == today { return "Heute" }
        if d == Calendar.current.date(byAdding: .day, value: 1, to: today) { return "Morgen" }
        return d.formatted(.dateTime.weekday(.abbreviated).day().month())
    }

    static func hourly(_ input: [Slot]) -> [Slot] {
        var out: [Slot] = []
        var bucket: [Slot] = []
        let cal = Calendar.current
        func flush() {
            guard let first = bucket.first else { return }
            let avg = bucket.map(\.total).reduce(0, +) / Double(bucket.count)
            let level = bucket.max { $0.total < $1.total }?.level ?? first.level
            out.append(Slot(id: first.id, total: avg, level: level))
            bucket = []
        }
        for s in input {
            if let first = bucket.first,
               cal.component(.hour, from: first.id) != cal.component(.hour, from: s.id)
                || !cal.isDate(first.id, inSameDayAs: s.id) {
                flush()
            }
            bucket.append(s)
        }
        flush()
        return out
    }

    // MARK: Cache

    static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TibberPrice", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cache.json")
    }

    private var cacheUsable: Bool {
        guard !slots.isEmpty else { return false }
        guard let m = (try? FileManager.default.attributesOfItem(atPath: Self.cacheURL.path))?[.modificationDate] as? Date else {
            return false
        }
        // Preise ändern sich 1x/Tag; 6 h Cache reicht und schont das Rate-Limit.
        let fresh = now.timeIntervalSince(m) < 6 * 3600
            && slots.contains { $0.id > now.addingTimeInterval(3600) }
        guard fresh else { return false }
        // Preise für morgen kommen meist ab 13 Uhr: bis sie da sind, viertelstündlich nachfragen.
        if Calendar.current.component(.hour, from: now) >= 13 {
            let tomorrow = Calendar.current.date(byAdding: .day, value: 1,
                                                 to: Calendar.current.startOfDay(for: now))!
            return slots.contains { $0.id >= tomorrow }
        }
        return true
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let (s, c) = try? GraphQL.parse(data) else { return }
        slots = s
        currency = c
        updated = (try? FileManager.default.attributesOfItem(atPath: Self.cacheURL.path))?[.modificationDate] as? Date
    }

    // MARK: Netz

    func refresh() async {
        guard let t = token else { needsToken = true; return }
        loading = true
        status = nil
        defer { loading = false }
        do {
            var req = URLRequest(url: GraphQL.endpoint, timeoutInterval: 20)
            req.httpMethod = "POST"
            req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.setValue("TibberPrice/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
            req.httpBody = try JSONEncoder().encode(["query": GraphQL.query])
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 429 { throw AppError.msg("Rate-Limit (429) – bitte später erneut") }
            if code == 401 || code == 403 { throw AppError.msg("Token ungültig – unten „Token“") }
            guard code == 200 else { throw AppError.msg("HTTP \(code)") }
            let (s, c) = try GraphQL.parse(data)
            guard !s.isEmpty else { throw AppError.msg("Keine Preise erhalten") }
            slots = s
            currency = c
            updated = Date()
            needsToken = false
            try? data.write(to: Self.cacheURL)
        } catch {
            status = error.localizedDescription
        }
    }

    func saveToken(_ raw: String) {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        TokenStore.save(t)
        token = t
        needsToken = false
        startLoop()
        Task { await refresh() }
    }

    // MARK: Takt

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                let n = Date()
                let step = 15 * 60.0
                let next = (floor(n.timeIntervalSince1970 / step) + 1) * step + 2
                try? await Task.sleep(for: .seconds(max(1, next - n.timeIntervalSince1970)))
                guard let self, !Task.isCancelled else { return }
                self.now = Date()
                if !self.cacheUsable { await self.refresh() }
            }
        }
    }
}

// MARK: - Chart

struct PriceChart: View {
    let slots: [Slot]
    let currency: String
    let now: Date
    let slotSeconds: TimeInterval

    var onHover: (Slot?) -> Void = { _ in }

    @State private var hoverX: CGFloat?

    private let padLeft: CGFloat = 22
    private let padRight: CGFloat = 4
    private let padTop: CGFloat = 8
    private let padBottom: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let hov = hoverIndex(width: w)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    draw(&ctx, size: size, hover: hov)
                }
                if let i = hov {
                    tooltip(slots[i])
                        .fixedSize()
                        .position(x: min(max(xMid(for: i, width: w), 64), max(w - 64, 64)), y: 26)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let p):
                    hoverX = p.x
                    onHover(index(atX: p.x, width: w).map { slots[$0] })
                case .ended:
                    hoverX = nil
                    onHover(nil)
                }
            }
        }
    }

    // MARK: Geometrie

    private func x(for i: Int, width: CGFloat) -> CGFloat {
        let plotW = max(1, width - padLeft - padRight)
        return padLeft + plotW * CGFloat(i) / CGFloat(max(slots.count - 1, 1))
    }

    /// Mitte der Stufe für Slot i (dort liegt der Punkt auf der Treppe).
    private func xMid(for i: Int, width: CGFloat) -> CGFloat {
        let a = x(for: i, width: width)
        guard i < slots.count - 1 else { return a }
        return (a + x(for: i + 1, width: width)) / 2
    }

    private func hoverIndex(width: CGFloat) -> Int? {
        guard let hx = hoverX else { return nil }
        return index(atX: hx, width: width)
    }

    private func index(atX hx: CGFloat, width: CGFloat) -> Int? {
        guard slots.count > 1 else { return nil }
        let plotW = width - padLeft - padRight
        guard plotW > 0 else { return nil }
        let f = (hx - padLeft) / plotW
        guard f >= -0.02, f <= 1.02 else { return nil }
        return min(max(Int((f * CGFloat(slots.count - 1)).rounded()), 0), slots.count - 1)
    }

    private func dayName(_ d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "Heute" }
        if Calendar.current.isDateInTomorrow(d) { return "Morgen" }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }

    private func timeRange(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: d)) – \(f.string(from: d.addingTimeInterval(slotSeconds)))"
    }

    private func tooltip(_ s: Slot) -> some View {
        VStack(spacing: 1) {
            Text(priceString(s.total, currency))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.text)
                .monospacedDigit()
            Text("\(dayName(s.id)), \(timeRange(s.id))")
                .font(.system(size: 9))
                .foregroundStyle(Palette.dim)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color(white: 0.17), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10)))
        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
        .allowsHitTesting(false)
    }

    // MARK: Zeichnen

    private func draw(_ ctx: inout GraphicsContext, size: CGSize, hover: Int?) {
        guard slots.count > 1 else { return }
        let plotW = max(1, size.width - padLeft - padRight)
        let plotH = max(1, size.height - padTop - padBottom)

        let vals = slots.map(\.total)
        let lo = vals.min() ?? 0
        let hi = vals.max() ?? 1
        let pad = max((hi - lo) * 0.18, 0.005)
        let minV = max(0, lo - pad)
        let maxV = hi + pad

        func px(_ i: Int) -> CGFloat {
            padLeft + plotW * CGFloat(i) / CGFloat(slots.count - 1)
        }
        func py(_ v: Double) -> CGFloat {
            padTop + plotH * (1 - CGFloat((v - minV) / (maxV - minV)))
        }

        // Gitter + y-Beschriftung
        for tick in ticks(minV, maxV) {
            let ty = py(tick)
            var p = Path()
            p.move(to: CGPoint(x: padLeft, y: ty))
            p.addLine(to: CGPoint(x: padLeft + plotW, y: ty))
            ctx.stroke(p, with: .color(.white.opacity(0.07)), lineWidth: 1)
            let label = currency == "EUR"
                ? String(format: "%.0f", tick * 100)
                : String(format: "%.2f", tick)
            ctx.draw(ctx.resolve(Text(label).font(.system(size: 9)).foregroundColor(Palette.faint)),
                     at: CGPoint(x: padLeft - 5, y: ty), anchor: .trailing)
        }

        let base = padTop + plotH
        let span = max(hi - lo, 0.0001)
        func tint(_ v: Double) -> Color { priceColor((v - lo) / span) }

        // Treppe: Säule pro Viertelstunde, Wert konstant bis zum nächsten Slot
        for i in 1..<slots.count {
            let c = tint(vals[i - 1])
            var column = Path()
            column.move(to: CGPoint(x: px(i - 1), y: base))
            column.addLine(to: CGPoint(x: px(i - 1), y: py(vals[i - 1])))
            column.addLine(to: CGPoint(x: px(i), y: py(vals[i - 1])))
            column.addLine(to: CGPoint(x: px(i), y: base))
            column.closeSubpath()
            ctx.fill(column, with: .color(c.opacity(0.20)))

            var step = Path()
            step.move(to: CGPoint(x: px(i - 1), y: py(vals[i - 1])))
            step.addLine(to: CGPoint(x: px(i), y: py(vals[i - 1])))
            step.addLine(to: CGPoint(x: px(i), y: py(vals[i])))
            ctx.stroke(step, with: .color(c),
                       style: StrokeStyle(lineWidth: 1.6, lineCap: .butt, lineJoin: .miter))
        }

        // Jetzt-Markierung (gestrichelt)
        if now >= slots[0].id, let idx = slots.lastIndex(where: { $0.id <= now }) {
            let elapsed = now.timeIntervalSince(slots[idx].id) / slotSeconds
            let nx: CGFloat
            if idx < slots.count - 1 {
                nx = px(idx) + (px(idx + 1) - px(idx)) * CGFloat(min(max(elapsed, 0), 1))
            } else {
                nx = px(idx)
            }
            var vline = Path()
            vline.move(to: CGPoint(x: nx, y: padTop))
            vline.addLine(to: CGPoint(x: nx, y: base))
            ctx.stroke(vline, with: .color(.white.opacity(0.35)),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            let cy = py(slots[idx].total)
            let dot = CGRect(x: nx - 5, y: cy - 5, width: 10, height: 10)
            ctx.fill(Path(ellipseIn: dot), with: .color(Palette.bg))
            ctx.stroke(Path(ellipseIn: dot), with: .color(Palette.cheap), lineWidth: 2.5)
        }

        // Hover-Markierung
        if let i = hover {
            let hx = i < slots.count - 1 ? (px(i) + px(i + 1)) / 2 : px(i)
            var vline = Path()
            vline.move(to: CGPoint(x: hx, y: padTop))
            vline.addLine(to: CGPoint(x: hx, y: base))
            ctx.stroke(vline, with: .color(.white.opacity(0.55)), lineWidth: 1)
            let cy = py(vals[i])
            let dot = CGRect(x: hx - 4.5, y: cy - 4.5, width: 9, height: 9)
            ctx.fill(Path(ellipseIn: dot), with: .color(Palette.bg))
            ctx.stroke(Path(ellipseIn: dot), with: .color(tint(vals[i])), lineWidth: 2.5)
        }

        // x-Beschriftung alle 4 Stunden
        var lastLabelX: CGFloat = -100
        for (i, s) in slots.enumerated() {
            let comps = Calendar.current.dateComponents([.hour, .minute], from: s.id)
            guard let h = comps.hour, h % 4 == 0, comps.minute == 0 else { continue }
            let lx = px(i)
            guard lx - lastLabelX > 30 else { continue }
            lastLabelX = lx
            ctx.draw(ctx.resolve(Text(String(format: "%02d", h)).font(.system(size: 9)).foregroundColor(Palette.faint)),
                     at: CGPoint(x: lx, y: base + 4), anchor: .top)
        }
    }

    private func ticks(_ lo: Double, _ hi: Double) -> [Double] {
        let raw = (hi - lo) / 4
        guard raw > 0 else { return [lo] }
        let mag = pow(10, floor(log10(raw)))
        let norm = raw / mag
        let step = (norm <= 1 ? 1 : norm <= 2 ? 2 : norm <= 5 ? 5 : 10) * mag
        var out: [Double] = []
        var v = (lo / step).rounded(.up) * step
        while v < hi {
            out.append(v)
            v += step
        }
        return out
    }
}

// MARK: - Views

struct RingView: View {
    let slot: Slot?
    let currency: String
    let position: Double
    let slotSeconds: TimeInterval

    var body: some View {
        let color = priceColor(position)
        // Füllstand = Preis-Lage: leer = günstigster, voll = teuerster Slot des Zeitraums.
        let fraction = min(max(position, 0), 1)
        ZStack {
            Circle().stroke(Color.white.opacity(0.10), lineWidth: 10)
            Circle()
                .trim(from: 0, to: max(fraction, 0.02))
                .stroke(color, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: color.opacity(0.45), radius: 5)
                .animation(.easeInOut(duration: 0.3), value: fraction)
                .animation(.easeInOut(duration: 0.3), value: position)
            VStack(spacing: 1) {
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(slot.map { amountString($0.total, currency) } ?? "–")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.text)
                        .monospacedDigit()
                    Text(unitString(currency))
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.text)
                }
                Text(rangeText)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
                    .monospacedDigit()
            }
            .animation(.easeInOut(duration: 0.2), value: slot?.id)
        }
        .frame(width: 132, height: 132)
        .padding(.vertical, 2)
    }

    private var rangeText: String {
        guard let s = slot else { return "keine Daten" }
        let end = s.id.addingTimeInterval(slotSeconds)
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return "\(f.string(from: s.id)) – \(f.string(from: end))"
    }
}

struct Segmented: View {
    let options: [String]
    let selection: Int
    let action: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, label in
                Button { action(i) } label: {
                    Text(label)
                        .font(.system(size: 11, weight: selection == i ? .semibold : .regular))
                        .foregroundStyle(selection == i ? Palette.text : Palette.dim)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selection == i ? Palette.pill : .clear, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: Capsule())
    }
}

struct TokenForm: View {
    @ObservedObject var store: Store
    var onClose: (() -> Void)? = nil
    @State private var input = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Tibber API-Token").font(.headline).foregroundStyle(Palette.text)
                Spacer()
                if store.hasToken, let onClose {
                    Button("Zurück") { onClose() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.dim)
                }
            }
            Text("developer.tibber.com → Token. Wird nur in der Keychain gespeichert.")
                .font(.caption).foregroundStyle(Palette.dim).fixedSize(horizontal: false, vertical: true)
            SecureField("Token einfügen", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { store.saveToken(input) }
            HStack {
                Spacer()
                Button("Speichern") { store.saveToken(input) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}

struct SettingsScreen: View {
    @ObservedObject var store: Store
    var onClose: () -> Void

    @State private var launchAtLogin = LoginItem.enabled
    @State private var error: String?
    @AppStorage("hoverOpen") private var hoverOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Einstellungen").font(.headline).foregroundStyle(Palette.text)
                Spacer()
                Button("Zurück") { onClose() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.dim)
            }
            Toggle("Beim Anmelden starten", isOn: Binding(
                get: { launchAtLogin },
                set: { v in
                    launchAtLogin = v
                    error = LoginItem.set(v)
                    launchAtLogin = LoginItem.enabled
                }
            ))
            Toggle("Beim Drüberfahren öffnen", isOn: $hoverOpen)
            if let error {
                Text(error).font(.system(size: 10)).foregroundStyle(Palette.expensive)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Token liegt in ~/Library/Application Support/TibberPrice/token (nur für dich lesbar).")
                .font(.system(size: 10)).foregroundStyle(Palette.faint)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .toggleStyle(.switch)
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
    }
}

struct ContentView: View {
    @ObservedObject var store: Store
    @State private var screen: Screen
    @State private var hovered: Slot?

    enum Screen { case prices, token, settings }

    init(store: Store, initialScreen: Screen = .prices) {
        self.store = store
        _screen = State(initialValue: initialScreen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if store.needsToken || screen == .token {
                TokenForm(store: store, onClose: { screen = .prices })
            } else if screen == .settings {
                SettingsScreen(store: store, onClose: { screen = .prices })
            } else {
                topBar
                let shown = hovered ?? store.currentSlot
                RingView(slot: shown, currency: store.currency,
                         position: shown.map { store.position($0.total) } ?? 0.5,
                         slotSeconds: hovered != nil && store.hourly ? 3600 : store.slotSeconds)
                    .animation(.easeInOut(duration: 0.3), value: hovered?.id)
                    .frame(maxWidth: .infinity)
                averageLine
                rangePicker
                chart
                if let err = store.status {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.expensive)
                        Text(err).font(.caption).foregroundStyle(Palette.dim)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Divider().overlay(Color.white.opacity(0.08))
            footer
        }
        .padding(14)
        .frame(width: 380)
        .background(Palette.bg)
        .environment(\.colorScheme, .dark)
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text("Strompreis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.text)
            Spacer()
            if store.loading { ProgressView().controlSize(.mini).tint(Palette.cheap) }
            Segmented(options: ["15 Min", "60 Min"], selection: store.hourly ? 1 : 0) { i in
                store.hourly = i == 1
            }
            .frame(width: 118)
        }
    }

    private var averageLine: some View {
        VStack(spacing: 1) {
            Text(store.visibleSlots.isEmpty
                 ? "Durchschnittspreis: –"
                 : "Durchschnittspreis: \(priceString(store.visibleAverage, store.currency))")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Palette.text)
            Text("Inkl. Steuern & Abgaben")
                .font(.system(size: 10))
                .foregroundStyle(Palette.dim)
        }
        .frame(maxWidth: .infinity)
    }

    private var rangePicker: some View {
        Segmented(
            options: ["Heute", "Morgen", "2 Tage"],
            selection: store.span2 ? 2 : (store.activeDay == Calendar.current.startOfDay(for: store.now) ? 0 : 1)
        ) { i in
            switch i {
            case 0:
                store.span2 = false
                store.selectedDay = Calendar.current.startOfDay(for: store.now)
            case 1:
                store.span2 = false
                store.selectedDay = Calendar.current.date(byAdding: .day, value: 1,
                                                         to: Calendar.current.startOfDay(for: store.now))
            default:
                store.span2 = true
                store.selectedDay = Calendar.current.startOfDay(for: store.now)
            }
            hovered = nil
        }
    }

    private var chart: some View {
        Group {
            if store.chartSlots.count < 2 {
                VStack(spacing: 4) {
                    Text(emptyMessage)
                        .font(.caption).foregroundStyle(Palette.dim)
                    if store.isTomorrow(store.activeDay) {
                        Text("Meist ab 13 Uhr verfügbar.")
                            .font(.system(size: 10)).foregroundStyle(Palette.faint)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                PriceChart(slots: store.chartSlots, currency: store.currency,
                           now: store.now, slotSeconds: store.hourly ? 3600 : store.slotSeconds,
                           onHover: { hovered = $0 })
                    .frame(height: 150)
                    .overlay(alignment: .topLeading) {
                        Text("cent").font(.system(size: 9)).foregroundColor(Palette.faint)
                    }
                HStack(spacing: 4) {
                    Spacer()
                    if let c = store.currentSlot {
                        Text("\(levelLabel(store.position(c.total))) · \(priceString(c.total, store.currency))")
                            .font(.system(size: 9))
                            .foregroundStyle(priceColor(store.position(c.total)))
                    }
                }
            }
        }
    }

    private var emptyMessage: String {
        store.isTomorrow(store.activeDay) ? "Preise für morgen noch nicht veröffentlicht." : "Für diesen Tag liegen keine Preise vor."
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(store.updated.map { "Stand \($0.formatted(date: .omitted, time: .shortened))" } ?? "keine Daten")
                .font(.system(size: 10)).foregroundStyle(Palette.faint)
            Spacer()
            if store.loading {
                ProgressView().controlSize(.mini)
            } else {
                Button("Aktualisieren") { Task { await store.refresh() } }
                    .buttonStyle(.plain)
            }
            Button("Token") { screen = .token }
                .buttonStyle(.plain)
            Button("Einstellungen") { screen = .settings }
                .buttonStyle(.plain)
            Button("Beenden") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
        }
        .font(.system(size: 10))
        .foregroundStyle(Palette.dim)
    }
}

// MARK: - Statusleiste

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private var store: Store?
    private var bag = Set<AnyCancellable>()
    private var hoverWork: DispatchWorkItem?
    private var watch: Task<Void, Never>?
    private var openedByHover = false
    private var lastCloseAt = Date.distantPast
    private var localMonitor: Any?

    private var hoverOpen: Bool { UserDefaults.standard.bool(forKey: "hoverOpen") }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let store = Store()
        self.store = store
        let hosting = NSHostingController(rootView: ContentView(store: store))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.delegate = self
        popover.behavior = .transient
        popover.animates = false

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.target = self
            button.action = #selector(buttonClicked)
            button.sendAction(on: [.leftMouseUp])
            button.addTrackingArea(NSTrackingArea(
                rect: button.bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
            updateTitle()
        }

        // Menüleisten-Text mit dem Store mitziehen
        store.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateTitle() }
            }
            .store(in: &bag)
    }

    private func updateTitle() {
        guard let store, let button = statusItem?.button else { return }
        button.title = store.currentSlot.map { priceString($0.total, store.currency) } ?? "– ct"
        button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    }

    @objc private func buttonClicked() {
        // transient schließt beim Klick schon selbst – dann nicht sofort wieder öffnen
        guard Date().timeIntervalSince(lastCloseAt) > 0.25 else { return }
        if popover.isShown { closePopover() } else { showPopover(hover: false) }
    }

    private func showPopover(hover: Bool) {
        guard let button = statusItem?.button, !popover.isShown else { return }
        openedByHover = hover
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        watchClicks()
        if hover { startLeaveWatch() }
    }

    private func closePopover() {
        watch?.cancel()
        hoverWork?.cancel()
        removeClickWatch()
        popover.performClose(nil)
        openedByHover = false
    }

    /// Erster Klick im Popover pinnt es: kein Auto-Schließen mehr beim Verlassen der Maus.
    private func watchClicks() {
        removeClickWatch()
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if self.popover.isShown,
               event.window === self.popover.contentViewController?.view.window {
                self.openedByHover = false
                self.watch?.cancel()
            }
            return event
        }
    }

    private func removeClickWatch() {
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        localMonitor = nil
    }

    /// Schließt nur, wenn per Hover geöffnet und die Maus weder über Popover noch Icon steht.
    private func startLeaveWatch() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(150))
                guard let self else { return }
                let p = NSEvent.mouseLocation
                let inPopover = self.popover.contentViewController?.view.window?.frame.contains(p) ?? false
                let inButton = self.statusItem?.button?.window?.frame.contains(p) ?? false
                if !inPopover && !inButton {
                    self.closePopover()
                    return
                }
            }
        }
    }

    @objc(mouseEntered:) func hoverEnter(_ event: NSEvent) {
        guard hoverOpen, !popover.isShown else { return }
        hoverWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.showPopover(hover: true) }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    @objc(mouseExited:) func hoverExit(_ event: NSEvent) {
        hoverWork?.cancel()
        guard openedByHover, popover.isShown else { return }
        startLeaveWatch()
    }
}

extension AppDelegate: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        lastCloseAt = Date()
        openedByHover = false
        watch?.cancel()
        removeClickWatch()
    }
}

// MARK: - App

struct TibberApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - Preview (Layout ohne Screen-Recording prüfen)

enum Preview {
    @MainActor static func run() {
        let store = Store(authenticate: false)
        let args = CommandLine.arguments
        let screen: ContentView.Screen = args.contains("--preview-settings") ? .settings
            : args.contains("--preview-token") ? .token : .prices
        let renderer = ImageRenderer(
            content: ContentView(store: store, initialScreen: screen)
                .environment(\.colorScheme, .dark)
                .background(Palette.bg)
        )
        renderer.scale = 2
        guard let img = renderer.nsImage,
              let tiff = img.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            print("render fehlgeschlagen")
            exit(1)
        }
        let url = URL(fileURLWithPath: "/tmp/tibber-preview.png")
        try? png.write(to: url)
        print("ok \(url.path)")
        exit(0)
    }
}

// MARK: - Self-Check

enum SelfCheck {
    static let sample = """
    {"data":{"viewer":{"homes":[{"currentSubscription":{"priceInfo":{
      "current":{"total":0.2951,"startsAt":"2026-10-23T16:00:00.000+02:00","level":"CHEAP","currency":"EUR"},
      "today":[
        {"total":0.30,"startsAt":"2026-10-22T00:00:00.000+02:00","level":"NORMAL","currency":"EUR"},
        {"total":0.20,"startsAt":"2026-10-23T00:00:00.000+02:00","level":"CHEAP","currency":"EUR"},
        {"total":0.40,"startsAt":"2026-10-23T00:15:00.000+02:00","level":"EXPENSIVE","currency":"EUR"}
      ],
      "tomorrow":[
        {"total":0.10,"startsAt":"2026-10-24T00:00:00.000+02:00","level":"VERY_CHEAP","currency":"EUR"}
      ]}}}]}}}
    """

    @MainActor static func run() {
        var fails = 0
        func check(_ cond: Bool, _ what: String) {
            if cond { print("ok   \(what)") } else { print("FAIL \(what)"); fails += 1 }
        }

        let parsed = try? GraphQL.parse(Data(sample.utf8))
        let slots = parsed?.slots ?? []
        check(slots.count == 4, "4 Slots geparst (bekam \(slots.count))")
        check(slots.map(\.id) == slots.map(\.id).sorted(), "Slots chronologisch")
        check(parsed?.currency == "EUR", "Währung EUR")
        check(slots.last?.total == 0.10, "Betrag korrekt")

        let now = ISO.frac.date(from: "2026-10-23T00:20:00.000+02:00")!
        check(pickCurrent(in: slots, at: now)?.id == ISO.frac.date(from: "2026-10-23T00:15:00.000+02:00"),
              "aktuelle Viertelstunde = 00:15")
        check(pickCurrent(in: slots, at: slots[0].id.addingTimeInterval(-60))?.id == slots[0].id,
              "vor dem ersten Slot -> erster Slot")

        check(priceString(0.2951, "EUR") == "29,5 ct", "Format EUR -> ct mit Komma")
        check(priceString(1.25, "NOK") == "1,250 NOK", "Format Fremdwährung")
        check(amountString(0.2951, "EUR") == "29,5", "Ringzahl ohne Einheit")

        let day = Calendar.current.startOfDay(for: ISO.frac.date(from: "2026-10-23T00:00:00.000+02:00")!)
        let daySlots = slots.filter { Calendar.current.isDate($0.id, inSameDayAs: day) }
        check(daySlots.count == 2, "Tagestrennung (bekam \(daySlots.count))")

        // Stunden-Aggregation: 8 Viertelstunden ab voller Stunde -> 2 Stunden
        let base = Calendar.current.dateInterval(of: .hour, for: Date(timeIntervalSince1970: 1_700_000_000))!.start
        let quarter = (0..<8).map { i in
            Slot(id: base.addingTimeInterval(Double(i) * 900), total: Double(i), level: "NORMAL")
        }
        let hours = Store.hourly(quarter)
        check(hours.count == 2, "Stunden-Aggregation (\(hours.count) Stunden)")
        check(hours.first.map { abs($0.total - 1.5) < 0.001 } ?? false, "Stundenmittel 1. Hälfte")
        check(hours.last.map { abs($0.total - 5.5) < 0.001 } ?? false, "Stundenmittel 2. Hälfte")

        func close(_ a: Color, _ b: Color) -> Bool {
            guard let ca = NSColor(a).usingColorSpace(.sRGB),
                  let cb = NSColor(b).usingColorSpace(.sRGB) else { return false }
            return abs(ca.redComponent - cb.redComponent) < 0.01
                && abs(ca.greenComponent - cb.greenComponent) < 0.01
                && abs(ca.blueComponent - cb.blueComponent) < 0.01
        }
        let emptyTomorrow = sample.replacingOccurrences(
            of: """
            "tomorrow":[
                {"total":0.10,"startsAt":"2026-10-24T00:00:00.000+02:00","level":"VERY_CHEAP","currency":"EUR"}
              ]
            """,
            with: "\"tomorrow\":[]")
        let withoutTomorrow = try? GraphQL.parse(Data(emptyTomorrow.utf8))
        check(withoutTomorrow?.slots.count == 3, "leeres tomorrow wird akzeptiert")
        check(withoutTomorrow?.currency == "EUR", "Währung auch ohne morgige Preise")

        check(AppDelegate().responds(to: NSSelectorFromString("mouseEntered:")), "Hover-Selector mouseEntered:")
        check(AppDelegate().responds(to: NSSelectorFromString("mouseExited:")), "Hover-Selector mouseExited:")

        check(priceColor(0) == Palette.cheap, "Farbe günstig = Türkis")
        check(close(priceColor(1), Palette.veryExpensive), "Farbe teuer = Rot")
        check(!close(priceColor(0.2), priceColor(0.9)), "günstig und teuer unterscheidbar")
        check(levelLabel(0.1) == "günstig" && levelLabel(0.5) == "normal" && levelLabel(0.9) == "teuer",
              "Level-Text passt zur Farbe")

        print(fails == 0 ? "\nselfcheck: ok" : "\nselfcheck: \(fails) Fehler")
        exit(fails == 0 ? 0 : 1)
    }
}

@main
enum Main {
    static func main() {
        let args = CommandLine.arguments
        if args.contains("--selfcheck") { MainActor.assumeIsolated { SelfCheck.run() } }
        if args.contains(where: { $0.hasPrefix("--preview") }) { MainActor.assumeIsolated { Preview.run() } }
        if let i = args.firstIndex(of: "--login"), i + 1 < args.count {
            let what = args[i + 1]
            switch what {
            case "on", "off":
                let err = LoginItem.set(what == "on")
                print(err.map { "Fehler: \($0)" } ?? "ok, enabled=\(LoginItem.enabled)")
            default:
                print("enabled=\(LoginItem.enabled) status=\(SMAppService.mainApp.status.rawValue)")
            }
            exit(0)
        }
        if let i = args.firstIndex(of: "--set-token"), i + 1 < args.count {
            TokenStore.save(args[i + 1])
            print("Token in Keychain gespeichert.")
            exit(0)
        }
        TibberApp.main()
    }
}
