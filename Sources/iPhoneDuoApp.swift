//
//  iPhoneDuoApp.swift
//  iPhone Duo — один интерфейс на два iPhone.
//
//  Левый (верхний) iPhone — хост: считает физику, шлёт состояние правому
//  через MultipeerConnectivity (Bluetooth + Wi-Fi Direct), режим .unreliable.
//

import SwiftUI
import UIKit
import Combine
import MultipeerConnectivity
import WebKit
import AVFoundation
import CoreMotion
import CoreImage
import Photos
import PhotosUI

// MARK: - Базовые модели

enum DuoRole: String, Codable {
    case left
    case right

    var title: String { self == .left ? "Левый экран" : "Правый экран" }
    var badge: String { self == .left ? "ЛЕВЫЙ" : "ПРАВЫЙ" }
    var isHost: Bool { self == .left }

    var opposite: DuoRole { self == .left ? .right : .left }
}

enum DuoLayout: String, Codable, CaseIterable, Identifiable {
    case book
    case laptop

    var id: String { rawValue }
    var title: String { self == .book ? "Книжка рядом" : "Ноутбук друг над другом" }
    var short: String { self == .book ? "Книжка" : "Ноутбук" }
    var hint: String { self == .book ? "Плечом к плечу" : "Один над другим" }
}

/// Универсальный пакет состояния: тип, строка, числа, индекс, флаг.
struct DuoPacket: Codable {
    var t: String
    var s: String = ""
    var d: [Double] = []
    var i: Int = 0
    var f: Bool = false
}

/// Элемент «Полки быстрого обмена» (Duo Shelf).
struct ShelfItem: Identifiable {
    let id = UUID()
    var text: String = ""
    var imageBase64: String = ""
    var fromPeer: Bool = false
    var title: String { text.isEmpty ? "Фото" : text }

    var image: UIImage? {
        guard !imageBase64.isEmpty, let data = Data(base64Encoded: imageBase64) else { return nil }
        return UIImage(data: data)
    }
}

/// Перевод мировой координаты (0…2 через оба экрана) в локальную (0…1).
func duoLocalX(_ worldX: Double, _ role: DuoRole) -> Double {
    role == .left ? worldX : worldX - 1.0
}

// MARK: - Канал связи

final class DuoLink: NSObject, ObservableObject {
    static let serviceType = "iphoneduo"

    @Published var role: DuoRole? = nil
    @Published var layout: DuoLayout = .book
    @Published var connected = false
    @Published var peerName = ""
    @Published var statusText = "Ожидание второго iPhone…"
    @Published var shelf: [ShelfItem] = []
    @Published var lastError: String = ""

    private let myPeerID: MCPeerID
    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    private var handlers: [UUID: (DuoPacket) -> Void] = [:]
    private var frameHandlers: [UUID: (Data) -> Void] = [:]
    private var lastInvite = Date.distantPast

    override init() {
        let base = UIDevice.current.name
        // MCPeerID ограничен 63 байтами, добавляем короткий хвост для уникальности.
        let short = String(base.prefix(18))
        myPeerID = MCPeerID(displayName: "\(short)-\(Int.random(in: 100...999))")
        session = MCSession(peer: myPeerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
    }

    var myName: String { myPeerID.displayName }

    func connect(role: DuoRole, layout: DuoLayout) {
        self.role = role
        self.layout = layout
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()

        let adv = MCNearbyServiceAdvertiser(
            peer: myPeerID,
            discoveryInfo: ["role": role.rawValue, "layout": layout.rawValue],
            serviceType: DuoLink.serviceType
        )
        adv.delegate = self
        adv.startAdvertisingPeer()

        let br = MCNearbyServiceBrowser(peer: myPeerID, serviceType: DuoLink.serviceType)
        br.delegate = self
        br.startBrowsingForPeers()

        advertiser = adv
        browser = br
        statusText = "Поиск второго iPhone…"
    }

    func disconnect() {
        session.disconnect()
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        advertiser = nil
        browser = nil
        connected = false
        peerName = ""
        role = nil
        statusText = "Ожидание второго iPhone…"
    }

    // MARK: отправка

    func send(_ packet: DuoPacket, reliable: Bool = false) {
        guard !session.connectedPeers.isEmpty,
              let body = try? JSONEncoder().encode(packet) else { return }
        var data = Data([1])
        data.append(body)
        try? session.send(data, toPeers: session.connectedPeers,
                          with: reliable ? .reliable : .unreliable)
    }

    func sendFrame(_ jpeg: Data) {
        guard !session.connectedPeers.isEmpty else { return }
        var data = Data([2])
        data.append(jpeg)
        try? session.send(data, toPeers: session.connectedPeers, with: .unreliable)
    }

    // MARK: подписки

    func listen(_ handler: @escaping (DuoPacket) -> Void) -> UUID {
        let id = UUID()
        handlers[id] = handler
        return id
    }

    func stopListening(_ id: UUID) { handlers.removeValue(forKey: id) }

    func listenFrames(_ handler: @escaping (Data) -> Void) -> UUID {
        let id = UUID()
        frameHandlers[id] = handler
        return id
    }

    func stopFrameListening(_ id: UUID) { frameHandlers.removeValue(forKey: id) }

    // MARK: полка

    func pushText(_ text: String) {
        guard !text.isEmpty else { return }
        shelf.insert(ShelfItem(text: text, fromPeer: true), at: 0)
        send(DuoPacket(t: "shelf_text", s: text), reliable: true)
    }

    func pushImage(_ image: UIImage) {
        guard let data = image.duoJPEG(maxSide: 720) else { return }
        let b64 = data.base64EncodedString()
        shelf.insert(ShelfItem(imageBase64: b64, fromPeer: true), at: 0)
        send(DuoPacket(t: "shelf_image", s: b64), reliable: true)
        if shelf.count > 24 { shelf.removeLast(shelf.count - 24) }
    }

    func sendShelfItem(_ item: ShelfItem) {
        if !item.text.isEmpty {
            send(DuoPacket(t: "shelf_text", s: item.text), reliable: true)
        } else if !item.imageBase64.isEmpty {
            send(DuoPacket(t: "shelf_image", s: item.imageBase64), reliable: true)
        }
    }

    fileprivate func receive(_ packet: DuoPacket) {
        if packet.t == "shelf_text" {
            shelf.insert(ShelfItem(text: packet.s, fromPeer: true), at: 0)
        } else if packet.t == "shelf_image" {
            shelf.insert(ShelfItem(imageBase64: packet.s, fromPeer: true), at: 0)
        }
        if shelf.count > 24 { shelf.removeLast(shelf.count - 24) }
        for handler in Array(handlers.values) { handler(packet) }
    }
}

extension DuoLink: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        DispatchQueue.main.async {
            switch state {
            case .connected:
                self.connected = true
                self.peerName = peerID.displayName
                self.statusText = "Связь установлена"
            case .connecting:
                self.statusText = "Соединение…"
            case .notConnected:
                self.connected = false
                self.statusText = "Поиск второго iPhone…"
            @unknown default:
                self.connected = false
            }
        }
    }

    func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        guard let tag = data.first else { return }
        let body = Data(data.dropFirst())
        if tag == 1 {
            guard let packet = try? JSONDecoder().decode(DuoPacket.self, from: body) else { return }
            DispatchQueue.main.async { self.receive(packet) }
        } else if tag == 2 {
            DispatchQueue.main.async {
                for handler in Array(self.frameHandlers.values) { handler(body) }
            }
        }
    }

    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {}

    func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}

    func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}

    func session(_ session: MCSession, didReceiveCertificate certificate: [Any]?,
                 fromPeer peerID: MCPeerID, certificateHandler: @escaping (Bool) -> Void) {
        certificateHandler(true)
    }
}

extension DuoLink: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }

    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didNotStartAdvertisingPeer error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }
}

extension DuoLink: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        guard peerID != myPeerID else { return }
        guard session.connectedPeers.isEmpty, !connected else { return }
        guard Date().timeIntervalSince(lastInvite) > 3 else { return }
        // Приглашает только тот, чьё имя лексикографически меньше — без дублей.
        if myName < peerID.displayName {
            lastInvite = Date()
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 25)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

    func browser(_ browser: MCNearbyServiceBrowser,
                 didNotStartBrowsingForPeers error: Error) {
        DispatchQueue.main.async { self.lastError = error.localizedDescription }
    }
}

// MARK: - Тема

enum DuoTheme {
    static let bg = Color(red: 0.02, green: 0.03, blue: 0.06)
    static let panel = Color(red: 0.07, green: 0.08, blue: 0.13)
    static let cyan = Color(red: 0.25, green: 0.87, blue: 1.0)
    static let magenta = Color(red: 1.0, green: 0.32, blue: 0.75)
    static let violet = Color(red: 0.55, green: 0.45, blue: 1.0)
    static let lime = Color(red: 0.55, green: 1.0, blue: 0.55)
    static let amber = Color(red: 1.0, green: 0.75, blue: 0.3)

    static var backdrop: LinearGradient {
        LinearGradient(colors: [Color(red: 0.05, green: 0.06, blue: 0.12),
                                Color(red: 0.01, green: 0.01, blue: 0.03)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension View {
    func duoCard(_ radius: CGFloat = 20) -> some View {
        self.padding(14)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.055))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

extension UIImage {
    func duoJPEG(maxSide: CGFloat, quality: CGFloat = 0.5) -> Data? {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        let resized = renderer.image { _ in draw(in: CGRect(origin: .zero, size: newSize)) }
        return resized.jpegData(compressionQuality: quality)
    }
}

// MARK: - Датчик наклона

final class DuoTilt: ObservableObject {
    static let shared = DuoTilt()
    @Published var gx: Double = 0
    @Published var gy: Double = 0
    private let manager = CMMotionManager()

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 30.0
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion = motion else { return }
            self?.gx = motion.gravity.x
            self?.gy = motion.gravity.y
        }
    }

    func stop() {
        if manager.isDeviceMotionActive { manager.stopDeviceMotionUpdates() }
    }
}

// MARK: - Свет / вспышка

enum DuoTorch {
    static func set(_ on: Bool) {
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              device.hasTorch else { return }
        if (try? device.lockForConfiguration()) != nil {
            device.torchMode = on ? .on : .off
            device.unlockForConfiguration()
        }
    }
}

// MARK: - Синтезатор

final class DuoSynth {
    static let shared = DuoSynth()

    private let engine = AVAudioEngine()
    private var players: [AVAudioPlayerNode] = []
    private var cursor = 0
    private var started = false
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!

    func start() {
        guard !started else { return }
        started = true
        for _ in 0..<8 {
            let node = AVAudioPlayerNode()
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            players.append(node)
        }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        try? engine.start()
    }

    func play(freq: Double, duration: Double = 0.22) {
        start()
        guard let buffer = tone(freq: freq, duration: duration),
              !players.isEmpty else { return }
        let node = players[cursor % players.count]
        cursor += 1
        node.stop()
        node.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        node.play()
        if !engine.isRunning { try? engine.start() }
    }

    private func tone(freq: Double, duration: Double) -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let frames = AVAudioFrameCount(rate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        let total = Int(frames)
        for i in 0..<total {
            let t = Double(i) / rate
            let env = exp(-t * 5.5)
            let value = sin(2 * .pi * freq * t) * 0.55 + sin(2 * .pi * freq * 2 * t) * 0.2
            channel[i] = Float(value * env * 0.4)
        }
        return buffer
    }
}

// MARK: - Микрофон (уровень)

final class DuoMic: ObservableObject {
    static let shared = DuoMic()
    @Published var level: Double = 0
    private let engine = AVAudioEngine()
    private var running = false

    func start() {
        guard !running else { return }
        running = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .measurement,
                                 options: [.mixWithOthers, .defaultToSpeaker])
        try? session.setActive(true)
        let input = engine.inputNode
        let fmt = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buffer, _ in
            guard let channel = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += channel[i] * channel[i] }
            let rms = sqrt(sum / Float(n))
            DispatchQueue.main.async { self?.level = Double(min(1.0, rms * 11.0)) }
        }
        try? engine.start()
    }

    func stop() {
        guard running else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        running = false
    }
}

// MARK: - Приложения оболочки

enum DuoApp: String, CaseIterable, Identifiable {
    case home, telegram, browser, cinema, camera, laptop, standby
    case beatmaker, lightSync, gravity, maze, hockey, pong, space
    case seabattle, tanks, highway, pinball, draw

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: return "Рабочий стол"
        case .telegram: return "Telegram Duo"
        case .browser: return "Duo Browser"
        case .cinema: return "Кинотеатр"
        case .camera: return "Duo Camera"
        case .laptop: return "Ноутбук"
        case .standby: return "StandBy"
        case .beatmaker: return "Beatmaker"
        case .lightSync: return "Light Sync"
        case .gravity: return "Gravity Sand"
        case .maze: return "Tilt Maze"
        case .hockey: return "Air Hockey"
        case .pong: return "Duo Pong"
        case .space: return "Space Battle"
        case .seabattle: return "Sea Battle"
        case .tanks: return "Duo Tanks"
        case .highway: return "Duo Highway"
        case .pinball: return "Duo Pinball"
        case .draw: return "Duo Draw"
        }
    }

    var shortTitle: String {
        switch self {
        case .home: return "Duo"
        case .telegram: return "TG"
        case .browser: return "Web"
        case .cinema: return "Кино"
        case .camera: return "Камера"
        case .laptop: return "Блокнот"
        case .standby: return "Часы"
        case .beatmaker: return "Бит"
        case .lightSync: return "Свет"
        case .gravity: return "Песок"
        case .maze: return "Лаб."
        case .hockey: return "Хоккей"
        case .pong: return "Понг"
        case .space: return "Космос"
        case .seabattle: return "Море"
        case .tanks: return "Танки"
        case .highway: return "Гонка"
        case .pinball: return "Пинбол"
        case .draw: return "Рис."
        }
    }

    var icon: String {
        switch self {
        case .home: return "square.grid.2x2.fill"
        case .telegram: return "paperplane.fill"
        case .browser: return "safari.fill"
        case .cinema: return "play.rectangle.fill"
        case .camera: return "camera.fill"
        case .laptop: return "keyboard"
        case .standby: return "clock.fill"
        case .beatmaker: return "square.grid.3x3.fill"
        case .lightSync: return "lightbulb.fill"
        case .gravity: return "drop.fill"
        case .maze: return "circle.grid.cross.fill"
        case .hockey: return "circle.circle.fill"
        case .pong: return "circle.dashed"
        case .space: return "sparkles"
        case .seabattle: return "water.waves"
        case .tanks: return "scope"
        case .highway: return "car.fill"
        case .pinball: return "circle.hexagongrid.fill"
        case .draw: return "pencil.tip"
        }
    }

    var tint: Color {
        switch self {
        case .home: return DuoTheme.cyan
        case .telegram: return Color(red: 0.35, green: 0.68, blue: 1.0)
        case .browser: return DuoTheme.cyan
        case .cinema: return Color(red: 1.0, green: 0.35, blue: 0.35)
        case .camera: return DuoTheme.amber
        case .laptop: return Color(red: 0.7, green: 0.75, blue: 0.85)
        case .standby: return Color(red: 0.95, green: 0.55, blue: 0.25)
        case .beatmaker: return DuoTheme.magenta
        case .lightSync: return DuoTheme.violet
        case .gravity: return Color(red: 0.9, green: 0.75, blue: 0.45)
        case .maze: return DuoTheme.lime
        case .hockey: return DuoTheme.cyan
        case .pong: return Color(red: 0.6, green: 1.0, blue: 0.9)
        case .space: return Color(red: 0.55, green: 0.7, blue: 1.0)
        case .seabattle: return Color(red: 0.35, green: 0.65, blue: 0.95)
        case .tanks: return DuoTheme.amber
        case .highway: return Color(red: 1.0, green: 0.6, blue: 0.2)
        case .pinball: return DuoTheme.magenta
        case .draw: return DuoTheme.violet
        }
    }

    var isGame: Bool {
        switch self {
        case .gravity, .maze, .hockey, .pong, .space, .seabattle, .tanks, .highway, .pinball:
            return true
        default:
            return false
        }
    }

    var category: String {
        if isGame { return "Игры" }
        switch self {
        case .home, .telegram, .browser, .cinema, .camera: return "Основное"
        default: return "Утилиты"
        }
    }
}

// MARK: - Точка входа

@main
struct iPhoneDuoApp: App {
    @StateObject private var link = DuoLink()

    var body: some Scene {
        WindowGroup {
            DuoRootView()
                .environmentObject(link)
                .preferredColorScheme(.dark)
                .statusBar(hidden: true)
        }
    }
}

struct DuoRootView: View {
    @EnvironmentObject var link: DuoLink

    var body: some View {
        ZStack {
            DuoTheme.backdrop.ignoresSafeArea()
            if link.role == nil {
                DuoSetupView()
            } else {
                DuoShellView()
            }
        }
        .ignoresSafeArea(.keyboard)
    }
}

// MARK: - Выбор роли

struct DuoSetupView: View {
    @EnvironmentObject var link: DuoLink
    @State private var role: DuoRole = .left
    @State private var layout: DuoLayout = .book

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 6) {
                    Text("iPhone Duo")
                        .font(.system(size: 36, weight: .heavy, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(colors: [DuoTheme.cyan, DuoTheme.magenta],
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    Text("Два iPhone — один экран")
                        .font(.footnote).foregroundColor(.white.opacity(0.6))
                }
                .padding(.top, 26)

                Text("Выберите, какую половину держит этот телефон")
                    .font(.subheadline).foregroundColor(.white.opacity(0.7))

                HStack(spacing: 12) {
                    roleCard(.left, icon: "iphone.landscape", note: "Хост: физика и звук")
                    roleCard(.right, icon: "iphone.landscape", note: "Второй экран")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Расположение").font(.caption).foregroundColor(.white.opacity(0.5))
                    HStack(spacing: 10) {
                        ForEach(DuoLayout.allCases) { item in
                            Button {
                                layout = item
                            } label: {
                                VStack(spacing: 6) {
                                    Text(item.short).font(.subheadline.weight(.semibold))
                                    Text(item.hint).font(.caption2).foregroundColor(.white.opacity(0.5))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(layout == item ? DuoTheme.violet.opacity(0.25) : Color.white.opacity(0.05))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(layout == item ? DuoTheme.violet : Color.white.opacity(0.1),
                                                lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .duoCard()

                Button {
                    link.connect(role: role, layout: layout)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                        Text("Соединить два iPhone").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(
                        LinearGradient(colors: [DuoTheme.cyan, DuoTheme.violet],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .foregroundColor(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 8) {
                    Label("Bluetooth + Wi-Fi Direct (MultipeerConnectivity)", systemImage: "dot.radiowaves.left.and.right")
                    Label("Разрешите «Локальную сеть» на обоих iPhone", systemImage: "wifi")
                    Label("Один телефон — «Левый», второй — «Правый»", systemImage: "rectangle.split.2x1")
                }
                .font(.caption)
                .foregroundColor(.white.opacity(0.55))
                .frame(maxWidth: .infinity, alignment: .leading)
                .duoCard()

                if !link.lastError.isEmpty {
                    Text(link.lastError)
                        .font(.caption2)
                        .foregroundColor(DuoTheme.amber)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 30)
        }
    }

    private func roleCard(_ target: DuoRole, icon: String, note: String) -> some View {
        Button {
            role = target
        } label: {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 30))
                    .rotationEffect(.degrees(target == .left ? 0 : 180))
                Text(target.title).font(.subheadline.weight(.bold))
                Text(note).font(.caption2).foregroundColor(.white.opacity(0.5))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(role == target ? DuoTheme.cyan.opacity(0.18) : Color.white.opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(role == target ? DuoTheme.cyan : Color.white.opacity(0.1), lineWidth: 1)
            )
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Оболочка

struct DuoShellView: View {
    @EnvironmentObject var link: DuoLink
    @State private var current: DuoApp = .home
    @State private var showPicker = false

    var body: some View {
        VStack(spacing: 0) {
            DuoStatusBar()
            ZStack {
                DuoTheme.bg
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            DuoShelfBar(onPhoto: { showPicker = true })
            DuoDock(current: $current)
        }
        .background(DuoTheme.bg.ignoresSafeArea())
        .sheet(isPresented: $showPicker) {
            DuoImagePicker { image in
                link.pushImage(image)
                showPicker = false
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch current {
        case .home: HomeDuoView(open: { current = $0 })
        case .telegram: TelegramDuoView()
        case .browser: BrowserDuoView()
        case .cinema: CinemaDuoView()
        case .camera: CameraDuoView()
        case .laptop: LaptopDuoView()
        case .standby: StandbyDuoView()
        case .beatmaker: BeatmakerDuoView()
        case .lightSync: LightSyncDuoView()
        case .gravity: GravityDuoView()
        case .maze: MazeDuoView()
        case .hockey: HockeyDuoView()
        case .pong: PongDuoView()
        case .space: SpaceDuoView()
        case .seabattle: SeaBattleDuoView()
        case .tanks: TanksDuoView()
        case .highway: HighwayDuoView()
        case .pinball: PinballDuoView()
        case .draw: DrawDuoView()
        }
    }
}

struct DuoStatusBar: View {
    @EnvironmentObject var link: DuoLink

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(link.connected ? DuoTheme.lime : DuoTheme.amber)
                .frame(width: 9, height: 9)
                .overlay(
                    Circle().stroke((link.connected ? DuoTheme.lime : DuoTheme.amber).opacity(0.5), lineWidth: 5)
                        .opacity(link.connected ? 0.6 : 0.3)
                )
            VStack(alignment: .leading, spacing: 1) {
                Text(link.role?.badge ?? "DUO")
                    .font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundColor(DuoTheme.cyan)
                Text(link.connected ? (link.peerName.isEmpty ? link.statusText : "⇄ \(link.peerName)") : link.statusText)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.55))
                    .lineLimit(1)
            }
            Spacer()
            Text(link.layout.short.uppercased())
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.08)))
                .foregroundColor(.white.opacity(0.6))
            Button {
                link.disconnect()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.black.opacity(0.55))
    }
}

// MARK: - Полка быстрого обмена

struct DuoShelfBar: View {
    @EnvironmentObject var link: DuoLink
    var onPhoto: () -> Void
    @State private var flash = false

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(LinearGradient(colors: [DuoTheme.cyan.opacity(0.6), DuoTheme.magenta.opacity(0.6)],
                                     startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
            HStack(spacing: 8) {
                Text("DUO SHELF")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundColor(DuoTheme.cyan.opacity(0.8))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(link.shelf.prefix(12)) { item in
                            shelfChip(item)
                        }
                        if link.shelf.isEmpty {
                            Text("Перетащите сюда текст или фото — оно мгновенно окажется на втором iPhone")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.35))
                                .lineLimit(1)
                        }
                    }
                    .padding(.vertical, 5)
                }

                Button {
                    if let text = UIPasteboard.general.string, !text.isEmpty {
                        link.pushText(text)
                    }
                } label: {
                    Image(systemName: "text.bubble.fill").font(.system(size: 13))
                }
                .buttonStyle(.plain).foregroundColor(DuoTheme.cyan)

                Button(action: onPhoto) {
                    Image(systemName: "photo.fill").font(.system(size: 13))
                }
                .buttonStyle(.plain).foregroundColor(DuoTheme.magenta)
            }
            .padding(.horizontal, 10)
            .frame(height: 44)
            .background(Color.black.opacity(0.75))
        }
    }

    @ViewBuilder
    private func shelfChip(_ item: ShelfItem) -> some View {
        Button {
            UIPasteboard.general.string = item.text
            link.sendShelfItem(item)
        } label: {
            HStack(spacing: 4) {
                if let image = item.image {
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 26, height: 26)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    Text(item.text.prefix(22))
                        .font(.system(size: 10))
                        .lineLimit(1)
                }
                if item.fromPeer {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 7))
                        .foregroundColor(DuoTheme.lime)
                }
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .foregroundColor(.white.opacity(0.85))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Док

struct DuoDock: View {
    @Binding var current: DuoApp

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(DuoApp.allCases) { app in
                    Button {
                        current = app
                    } label: {
                        VStack(spacing: 4) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .fill(app.tint.opacity(current == app ? 0.3 : 0.13))
                                    .frame(width: 46, height: 46)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                                            .stroke(app.tint.opacity(current == app ? 0.9 : 0.22), lineWidth: 1)
                                    )
                                Image(systemName: app.icon)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(current == app ? .white : app.tint)
                            }
                            Text(app.shortTitle)
                                .font(.system(size: 8))
                                .foregroundColor(.white.opacity(current == app ? 0.9 : 0.4))
                                .lineLimit(1)
                        }
                        .frame(width: 54)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .background(Color.black.opacity(0.85))
        .overlay(Rectangle().fill(Color.white.opacity(0.08)).frame(height: 1), alignment: .top)
    }
}

// MARK: - Выбор фото

struct DuoImagePicker: UIViewControllerRepresentable {
    var onPick: (UIImage) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .photoLibrary
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onPick: (UIImage) -> Void
        init(onPick: @escaping (UIImage) -> Void) { self.onPick = onPick }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { onPick(image) }
            picker.dismiss(animated: true)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
    }
}

// MARK: - 1. Рабочий стол

struct HomeDuoView: View {
    @EnvironmentObject var link: DuoLink
    var open: (DuoApp) -> Void

    var body: some View {
        GeometryReader { geo in
            if link.role == .left {
                HStack(spacing: 0) {
                    clockPanel
                    Divider().background(Color.white.opacity(0.1))
                    quickTiles
                }
                .padding(.horizontal, 10)
            } else {
                appGrid(available: geo.size)
                    .padding(.horizontal, 10)
            }
        }
    }

    private var clockPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 2) {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 54, weight: .thin, design: .rounded))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.55))
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Label(link.connected ? "Duo-связь активна" : "Поиск партнёра",
                      systemImage: link.connected ? "checkmark.seal.fill" : "hourglass")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(link.connected ? DuoTheme.lime : DuoTheme.amber)
                Text(link.peerName.isEmpty ? "Второй iPhone ещё не подключён" : link.peerName)
                    .font(.caption2).foregroundColor(.white.opacity(0.5))
                HStack(spacing: 3) {
                    ForEach(0..<12, id: \.self) { i in
                        Capsule()
                            .fill(i % 2 == 0 ? DuoTheme.cyan.opacity(0.8) : DuoTheme.magenta.opacity(0.6))
                            .frame(width: 3, height: CGFloat(4 + (i % 4) * 3))
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .duoCard()

            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 4) {
                Text("iPhone Duo OS").font(.caption2.weight(.bold)).foregroundColor(DuoTheme.cyan)
                Text("19 режимов на два экрана. Роль: хост, 60 FPS.")
                    .font(.system(size: 10)).foregroundColor(.white.opacity(0.45))
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var quickTiles: some View {
        VStack(spacing: 8) {
            ForEach([DuoApp.telegram, .cinema, .browser, .camera], id: \.self) { app in
                Button { open(app) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: app.icon).foregroundColor(app.tint)
                        Text(app.title).font(.caption.weight(.semibold)).foregroundColor(.white)
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(width: 118)
        .padding(.vertical, 10)
    }

    private func appGrid(available: CGSize) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 10)], spacing: 12) {
                ForEach(DuoApp.allCases) { app in
                    Button { open(app) } label: {
                        VStack(spacing: 5) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(app.tint.opacity(0.16))
                                    .frame(height: 54)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .stroke(app.tint.opacity(0.35), lineWidth: 1)
                                    )
                                Image(systemName: app.icon)
                                    .font(.system(size: 20))
                                    .foregroundColor(app.tint)
                            }
                            Text(app.shortTitle)
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.7))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Web-панель

final class DuoWebBox: ObservableObject {
    weak var web: WKWebView?
    func back() { web?.goBack() }
    func forward() { web?.goForward() }
    func reload() { web?.reload() }
    func evaluate(_ js: String) { web?.evaluateJavaScript(js, completionHandler: nil) }
}

struct DuoWebView: UIViewRepresentable {
    var url: URL?
    var html: String?
    var userAgent: String?
    var spanOffset: Double = 0
    var span: Bool = false
    var reloadID: Int = 0
    var box: DuoWebBox?

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsAirPlayForMediaPlayback = true
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        let web = WKWebView(frame: .zero, configuration: config)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.allowsBackForwardNavigationGestures = true
        box?.web = web
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.offset = spanOffset
        context.coordinator.span = span
        if let agent = userAgent, web.customUserAgent != agent {
            web.customUserAgent = agent
        }
        if context.coordinator.loadedID != reloadID {
            context.coordinator.loadedID = reloadID
            if let html = html {
                web.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
            } else if let url = url {
                web.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 30))
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(offset: spanOffset, span: span)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var offset: Double
        var span: Bool
        var loadedID = -1
        private var applied = false

        init(offset: Double, span: Bool) {
            self.offset = offset
            self.span = span
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            applied = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if span { applySpan(webView) }
        }

        func applySpan(_ webView: WKWebView) {
            guard !applied else { return }
            applied = true
            let width = 1600
            let x = Int(Double(width) * min(max(offset, 0), 0.95))
            let js = """
            (function(){
              var m = document.querySelector('meta[name=viewport]');
              if (!m) { m = document.createElement('meta'); m.name='viewport'; document.head.appendChild(m); }
              m.setAttribute('content','width=\(width), initial-scale=1.0, maximum-scale=1.0, user-scalable=no');
              document.documentElement.style.width='\(width)px';
              if (document.body) { document.body.style.width='\(width)px'; }
              document.documentElement.style.overflowX='auto';
              setTimeout(function(){ window.scrollTo(\(x), 0); }, 350);
            })();
            """
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }
}

// MARK: - 2. Telegram Web

enum TelegramMode: String, CaseIterable, Identifiable {
    case span, dual
    var id: String { rawValue }
    var title: String { self == .span ? "Единый экран" : "Два окна" }
}

struct TelegramDuoView: View {
    @EnvironmentObject var link: DuoLink
    @State private var mode: TelegramMode = .span
    @State private var box = DuoWebBox()
    @State private var reloadID = 0
    @State private var urlText = "https://web.telegram.org/k/"

    private let desktopAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"
    private let mobileAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Mobile/15E148 Safari/604.1"

    private var url: URL? { URL(string: urlText) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                ForEach(TelegramMode.allCases) { item in
                    Button {
                        mode = item
                        reloadID += 1
                        link.send(DuoPacket(t: "tg_mode", i: item == .span ? 0 : 1), reliable: true)
                    } label: {
                        Text(item.title)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(mode == item ? DuoTheme.cyan.opacity(0.28) : Color.white.opacity(0.06)))
                            .foregroundColor(mode == item ? .white : .white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text(mode == .span ? "Span Mode · iPad UA" : "Dual Window")
                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
                Button { box.reload() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(DuoTheme.cyan)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.5))

            DuoWebView(url: url,
                       html: nil,
                       userAgent: mode == .span ? desktopAgent : mobileAgent,
                       spanOffset: link.role == .left ? 0 : 0.5,
                       span: mode == .span,
                       reloadID: reloadID,
                       box: box)
                .overlay(alignment: .bottomTrailing) {
                    if mode == .span {
                        Text("Половина \(link.role == .left ? "левая" : "правая")")
                            .font(.system(size: 8))
                            .padding(4)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .foregroundColor(.white.opacity(0.4))
                            .padding(6)
                    }
                }
        }
        .onAppear {
            box.web?.allowsBackForwardNavigationGestures = true
        }
    }
}

// MARK: - 3. Браузер

enum BrowserMode: String, CaseIterable, Identifiable {
    case span, tabs
    var id: String { rawValue }
    var title: String { self == .span ? "Широкий сайт" : "Две вкладки" }
}

struct BrowserDuoView: View {
    @EnvironmentObject var link: DuoLink
    @State private var mode: BrowserMode = .span
    @State private var box = DuoWebBox()
    @State private var reloadID = 0
    @State private var input = ""
    @State private var tabs = ["https://www.wikipedia.org", "https://news.ycombinator.com"]
    @State private var activeTab = 0
    @State private var spanURL = "https://www.wikipedia.org"

    private var currentURL: String {
        mode == .span ? spanURL : tabs[min(activeTab, tabs.count - 1)]
    }

    private var url: URL? {
        let raw = currentURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        if raw.hasPrefix("http") { return URL(string: raw) }
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw
        return URL(string: "https://www.google.com/search?q=\(encoded)")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { box.back() } label: { Image(systemName: "chevron.left") }.buttonStyle(.plain)
                Button { box.forward() } label: { Image(systemName: "chevron.right") }.buttonStyle(.plain)
                Button { box.reload() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.plain)
                TextField("Поиск или адрес", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .onSubmit { go() }
                Button { go() } label: { Image(systemName: "arrow.right.circle.fill") }.buttonStyle(.plain)
            }
            .font(.system(size: 13))
            .foregroundColor(DuoTheme.cyan)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.black.opacity(0.5))

            HStack(spacing: 8) {
                ForEach(BrowserMode.allCases) { item in
                    Button {
                        mode = item
                        reloadID += 1
                    } label: {
                        Text(item.title)
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 4)
                            .background(Capsule().fill(mode == item ? DuoTheme.violet.opacity(0.3) : Color.white.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                }
                if mode == .tabs {
                    ForEach(0..<tabs.count, id: \.self) { index in
                        Button {
                            activeTab = index
                            reloadID += 1
                        } label: {
                            Text("Вкладка \(index + 1)")
                                .font(.system(size: 10))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(activeTab == index ? DuoTheme.cyan.opacity(0.3) : Color.white.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("200% ширины на два экрана")
                        .font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
                }
                Spacer()
            }
            .padding(.horizontal, 10).padding(.bottom, 5)

            DuoWebView(url: url,
                       html: nil,
                       userAgent: mode == .span ? "Mozilla/5.0 (iPad; CPU OS 16_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.0 Safari/604.1" : nil,
                       spanOffset: link.role == .left ? 0 : 0.5,
                       span: mode == .span,
                       reloadID: reloadID,
                       box: box)
        }
        .onAppear {
            input = currentURL
            link.listen { packet in
                if packet.t == "browser_url" {
                    spanURL = packet.s
                    mode = .span
                    reloadID += 1
                    input = packet.s
                }
            }
        }
    }

    private func go() {
        var target = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if target.isEmpty { return }
        if !target.hasPrefix("http") && target.contains(".") {
            target = "https://" + target
        }
        if mode == .span {
            spanURL = target
            link.send(DuoPacket(t: "browser_url", s: target), reliable: true)
        } else {
            if tabs.isEmpty { tabs = [target] } else { tabs[min(activeTab, tabs.count - 1)] = target }
        }
        reloadID += 1
    }
}

// MARK: - 4. Кинотеатр

enum CinemaSource: String, CaseIterable, Identifiable {
    case player, youtube
    var id: String { rawValue }
    var title: String { self == .player ? "Видео / файл" : "YouTube" }
}

final class CinemaEngine: ObservableObject {
    let player = AVPlayer()
    @Published var playing = false
    @Published var source: CinemaSource = .player
    @Published var youtubeID = "aqz-KE-bpKQ"
    @Published var title = "Демо-ролик"
    @Published var muted = false
    @Published var position: Double = 0
    @Published var duration: Double = 0

    func load(url: URL, title: String) {
        source = .player
        self.title = title
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        player.play()
        playing = true
        observeTime()
    }

    private var observer: Any?

    func observeTime() {
        guard observer == nil else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        observer = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self = self else { return }
            self.position = time.seconds
            if let item = self.player.currentItem {
                let d = item.duration.seconds
                if d.isFinite { self.duration = d }
            }
        }
    }

    func play() {
        player.play()
        playing = true
    }

    func pause() {
        player.pause()
        playing = false
    }

    func seek(to seconds: Double) {
        let clamped = max(0, seconds)
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        position = clamped
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerUIView {
        let view = PlayerUIView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerUIView, context: Context) {
        if uiView.playerLayer.player !== player {
            uiView.playerLayer.player = player
        }
    }
}

final class PlayerUIView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct YouTubeView: UIViewRepresentable {
    var videoID: String
    var span: Bool
    var isRight: Bool
    var command: String
    var commandID: Int

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.isScrollEnabled = false
        web.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        if context.coordinator.videoID != videoID {
            context.coordinator.videoID = videoID
            web.loadHTMLString(html, baseURL: URL(string: "https://www.youtube.com"))
        }
        if context.coordinator.commandID != commandID, !command.isEmpty {
            context.coordinator.commandID = commandID
            let js = "document.querySelector('iframe').contentWindow.postMessage('{\"event\":\"command\",\"func\":\"\(command)\",\"args\":\"\"}','*');"
            web.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(videoID: videoID) }

    final class Coordinator {
        var videoID: String
        var commandID = -1
        init(videoID: String) { self.videoID = videoID }
    }

    private var html: String {
        let width = span ? "200%" : "100%"
        let shift = (span && isRight) ? "-50%" : "0%"
        return """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=1.0, user-scalable=no">
        <style>html,body{margin:0;padding:0;background:#000;overflow:hidden;height:100%}
        .wrap{width:\(width);height:100%;transform:translateX(\(shift))}
        iframe{width:100%;height:100%;border:0;display:block}</style></head>
        <body><div class="wrap"><iframe src="https://www.youtube.com/embed/\(videoID)?autoplay=1&playsinline=1&controls=0&rel=0&modestbranding=1&enablejsapi=1" allow="autoplay; encrypted-media" allowfullscreen></iframe></div></body></html>
        """
    }
}

struct CinemaDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var engine = CinemaEngine()
    @State private var input = ""

    @State private var useSpan = true
    @State private var command = ""
    @State private var commandID = 0
    @State private var showPicker = false
    @State private var timer = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private let demos: [(String, String)] = [
        ("aqz-KE-bpKQ", "Big Buck Bunny"),
        ("hHW1oY26kxQ", "Lo-Fi поток"),
        ("jNQXAC9IVRw", "Me at the zoo"),
        ("ScMzIvxBSi4", "Demo Clip")
    ]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if engine.source == .youtube {
                    YouTubeView(videoID: engine.youtubeID,
                                span: useSpan,
                                isRight: link.role == .right,
                                command: command,
                                commandID: commandID)
                } else {
                    PlayerLayerView(player: engine.player)
                        .onAppear { engine.player.isMuted = link.role == .right }
                }
                VStack {
                    Spacer()
                    controlBar
                }
            }
            .frame(maxHeight: .infinity)

            if engine.source == .youtube {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(demos, id: \.0) { demo in
                            Button {
                                engine.youtubeID = demo.0
                                engine.title = demo.1
                                engine.source = .youtube
                            } label: {
                                Text(demo.1).font(.system(size: 10))
                                    .padding(.horizontal, 9).padding(.vertical, 5)
                                    .background(Capsule().fill(Color.white.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 34)
            }

            HStack(spacing: 6) {
                TextField("YouTube ссылка или ID", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .autocapitalization(.none).disableAutocorrection(true)
                    .onSubmit { openInput() }
                Button { openInput() } label: {
                    Text("Открыть").font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Capsule().fill(DuoTheme.magenta.opacity(0.3)))
                }
                .buttonStyle(.plain)
                Button { showPicker = true } label: {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 13))
                }
                .buttonStyle(.plain).foregroundColor(DuoTheme.cyan)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
        }
        .onAppear {
            engine.load(url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!,
                        title: "Big Buck Bunny")
            engine.player.isMuted = link.role == .right
            link.listen { packet in
                guard packet.t == "cinema" else { return }
                if packet.s == "play" {
                    engine.play()
                } else if packet.s == "pause" {
                    engine.pause()
                } else if packet.s == "seek" {
                    engine.seek(to: packet.d.first ?? 0)
                } else if packet.s == "frame" {
                    let remote = packet.d.first ?? 0
                    if abs(remote - engine.player.currentTime().seconds) > 0.6 {
                        engine.seek(to: remote)
                    }
                } else if packet.s.hasPrefix("youtube:") {
                    engine.source = .youtube
                    engine.youtubeID = String(packet.s.dropFirst("youtube:".count))
                } else if packet.s.hasPrefix("url:") {
                    let raw = String(packet.s.dropFirst("url:".count))
                    if let url = URL(string: raw) {
                        engine.load(url: url, title: "Ссылка")
                    }
                }
            }
        }
        .onReceive(timer) { _ in
            guard link.role == .left else { return }
            if engine.source == .player {
                link.send(DuoPacket(t: "cinema", s: "frame", d: [engine.player.currentTime().seconds]))
            }
        }
        .sheet(isPresented: $showPicker) {
            DuoVideoPicker { url in
                engine.load(url: url, title: "Из галереи")
                showPicker = false
            }
        }
    }

    private var controlBar: some View {
        HStack(spacing: 14) {
            Button {
                let isPlaying = engine.source == .youtube ? false : engine.playing
                if engine.source == .youtube {
                    command = mediaCommand
                    commandID += 1
                } else if isPlaying {
                    engine.pause()
                } else {
                    engine.play()
                }
                link.send(DuoPacket(t: "cinema", s: isPlaying ? "pause" : "play"), reliable: true)
            } label: {
                Image(systemName: engine.playing || engine.source == .youtube ? "pause.fill" : "play.fill")
                    .font(.system(size: 20))
            }
            .buttonStyle(.plain)

            Button {
                if engine.source == .youtube {
                    command = "seekTo"; commandID += 1
                } else {
                    engine.seek(to: max(0, engine.position - 5))
                }
                link.send(DuoPacket(t: "cinema", s: "seek", d: [max(0, engine.position - 5)]), reliable: true)
            } label: { Image(systemName: "gobackward.5") }.buttonStyle(.plain)

            Button {
                if engine.source == .youtube {
                    command = "seekTo"; commandID += 1
                } else {
                    engine.seek(to: engine.position + 5)
                }
                link.send(DuoPacket(t: "cinema", s: "seek", d: [engine.position + 5]), reliable: true)
            } label: { Image(systemName: "goforward.5") }.buttonStyle(.plain)

            Text(engine.title).font(.system(size: 10)).lineLimit(1)
            Spacer()
            Text(link.role == .left ? "ЗВУК" : "MUTE")
                .font(.system(size: 8, weight: .bold))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundColor(.white.opacity(0.6))
        }
        .foregroundColor(.white)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(LinearGradient(colors: [.clear, Color.black.opacity(0.8)], startPoint: .top, endPoint: .bottom))
    }

    private var mediaCommand: String { "pauseVideo" }

    private func openInput() {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        if raw.hasPrefix("http") && !raw.contains("youtu") {
            if let url = URL(string: raw) {
                engine.load(url: url, title: "Ссылка")
                link.send(DuoPacket(t: "cinema", s: "url:\(raw)"), reliable: true)
            }
            return
        }
        var id = raw
        if let range = raw.range(of: "v=") {
            id = String(raw[range.upperBound...].prefix(11))
        } else if raw.contains("youtu.be/") {
            id = String((raw.split(separator: "/").last ?? "")).prefix(11).description
        }
        engine.youtubeID = id
        engine.title = "YouTube"
        engine.source = .youtube
        link.send(DuoPacket(t: "cinema", s: "youtube:\(id)"), reliable: true)
    }
}

struct DuoVideoPicker: UIViewControllerRepresentable {
    var onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .videos
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (URL) -> Void
        init(onPick: @escaping (URL) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let provider = results.first?.itemProvider,
                  provider.hasItemConformingToTypeIdentifier("public.movie") else { return }
            provider.loadFileRepresentation(forTypeIdentifier: "public.movie") { url, _ in
                guard let url = url else { return }
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent("duo-\(UUID().uuidString).mov")
                try? FileManager.default.copyItem(at: url, to: copy)
                DispatchQueue.main.async { self.onPick(copy) }
            }
        }
    }
}

// MARK: - 5. Удалённая камера

final class CameraEngine: NSObject, ObservableObject {
    enum Side { case camera, viewer }

    @Published var frame: UIImage?
    @Published var authorized = false
    @Published var torchOn = false
    @Published var note = ""

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "duo.camera.session")
    private let ciContext = CIContext()
    private var lastSent = Date.distantPast
    private var configured = false

    var onJPEG: ((Data) -> Void)?

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.authorized = granted
                    if granted { self.configureAndRun() } else { self.note = "Нет доступа к камере" }
                }
            }
        default:
            note = "Камера запрещена в настройках"
        }
    }

    private func configureAndRun() {
        authorized = true
        queue.async {
            guard !self.configured else {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }
            self.session.beginConfiguration()
            self.session.sessionPreset = .high
            if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
               let input = try? AVCaptureDeviceInput(device: device),
               self.session.canAddInput(input) {
                self.session.addInput(input)
            }
            if self.session.canAddOutput(self.videoOutput) {
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self, queue: self.queue)
                self.session.addOutput(self.videoOutput)
            }
            if self.session.canAddOutput(self.photoOutput) {
                self.session.addOutput(self.photoOutput)
            }
            self.session.commitConfiguration()
            self.configured = true
            self.session.startRunning()
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
        DuoTorch.set(false)
    }

    func capture() {
        let settings = AVCapturePhotoSettings()
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           device.hasTorch, torchOn {
            settings.flashMode = .on
        }
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func toggleTorch() {
        torchOn.toggle()
        DuoTorch.set(torchOn)
    }
}

extension CameraEngine: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard Date().timeIntervalSince(lastSent) > 0.11 else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lastSent = Date()
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = 420.0 / max(image.extent.width, 1)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let jpeg = ciContext.jpegRepresentation(of: scaled,
                                                      colorSpace: CGColorSpaceCreateDeviceRGB(),
                                                      options: [:])
        else { return }
        onJPEG?(jpeg)
    }
}

extension CameraEngine: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput,
                     didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else { return }
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        DispatchQueue.main.async {
            self.frame = image
            self.note = "Снимок сохранён в галерею"
        }
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewHost {
        let host = PreviewHost()
        host.previewLayer.session = session
        host.previewLayer.videoGravity = .resizeAspectFill
        return host
    }

    func updateUIView(_ uiView: PreviewHost, context: Context) {}

    final class PreviewHost: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}

struct CameraDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var engine = CameraEngine()
    @State private var isCameraSide = true
    @State private var packetID: UUID?
    @State private var frameID: UUID?

    var body: some View {
        ZStack {
            Color.black
            if isCameraSide {
                ZStack {
                    CameraPreviewView(session: engine.session)
                        .ignoresSafeArea()
                    VStack {
                        HStack {
                            Text("Видоискатель • камера")
                                .font(.system(size: 9))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Capsule().fill(Color.black.opacity(0.6)))
                            Spacer()
                            Button {
                                engine.toggleTorch()
                            } label: {
                                Image(systemName: engine.torchOn ? "bolt.fill" : "bolt.slash")
                                    .padding(8)
                                    .background(Circle().fill(Color.black.opacity(0.55)))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundColor(.white)
                        .padding(10)
                        Spacer()
                        Button {
                            engine.capture()
                            link.send(DuoPacket(t: "cam_photo", s: "shot"), reliable: true)
                        } label: {
                            Circle()
                                .stroke(Color.white, lineWidth: 4)
                                .frame(width: 68, height: 68)
                                .overlay(Circle().fill(Color.white).frame(width: 54, height: 54))
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 18)
                        Text(engine.note)
                            .font(.system(size: 9)).foregroundColor(.white.opacity(0.6))
                    }
                }
            } else {
                ZStack {
                    if let image = engine.frame {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                    } else {
                        VStack(spacing: 10) {
                            ProgressView().tint(.white)
                            Text("Поток с камеры второго iPhone")
                                .font(.caption).foregroundColor(.white.opacity(0.5))
                        }
                    }
                    VStack {
                        Spacer()
                        Button {
                            link.send(DuoPacket(t: "cam_shutter", s: "go"), reliable: true)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "camera.aperture")
                                Text("Спуск затвора").fontWeight(.semibold)
                            }
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .background(Capsule().fill(DuoTheme.amber.opacity(0.9)))
                            .foregroundColor(.black)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 16)
                    }
                }
            }
        }
        .overlay(alignment: .topLeading) {
            Button {
                isCameraSide.toggle()
                if isCameraSide { engine.start() } else { engine.stop() }
            } label: {
                Text(isCameraSide ? "Сделать вторым экраном" : "Включить камеру здесь")
                    .font(.system(size: 9))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.15)))
                    .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .padding(10)
        }
        .onAppear {
            isCameraSide = (link.role == .left)
            if isCameraSide { engine.start() }
            engine.onJPEG = { data in
                link.sendFrame(data)
            }
            packetID = link.listen { packet in
                if packet.t == "cam_shutter" {
                    engine.capture()
                } else if packet.t == "cam_photo" {
                    engine.note = "Второй iPhone сделал снимок"
                }
            }
            frameID = link.listenFrames { data in
                if let image = UIImage(data: data) {
                    engine.frame = image
                }
            }
        }
        .onDisappear {
            engine.stop()
            if let id = packetID { link.stopListening(id) }
            if let id = frameID { link.stopFrameListening(id) }
        }
    }
}

// MARK: - 6. Ноутбук

struct LaptopDuoView: View {
    @EnvironmentObject var link: DuoLink
    @State private var text = "iPhone Duo · блокнот\n\n"
    @State private var caret = 0
    @State private var preview = ""
    @State private var packetID: UUID?
    @State private var lastSync = Date.distantPast

    private var isEditor: Bool { link.role == .left }
    private let rows: [[String]] = [
        ["й", "ц", "у", "к", "е", "н", "г", "ш", "щ", "з", "х"],
        ["ф", "ы", "в", "а", "п", "р", "о", "л", "д", "ж", "э"],
        ["я", "ч", "с", "м", "и", "т", "ь", "б", "ю", "ъ"]
    ]

    var body: some View {
        Group {
            if isEditor { editor } else { keyboard }
        }
        .onAppear {
            packetID = link.listen { packet in
                switch packet.t {
                case "laptop_key":
                    insert(packet.s)
                case "laptop_backspace":
                    var chars = Array(text)
                    let safe = min(caret, chars.count)
                    if safe > 0 { chars.remove(at: safe - 1); text = String(chars); caret = safe - 1 }
                    syncPreview(force: true)
                case "laptop_move":
                    caret = min(max(0, caret + packet.i), text.count)
                case "laptop_newline":
                    insert("\n")
                case "laptop_clear":
                    text = ""
                    caret = 0
                    syncPreview(force: true)
                case "laptop_sync":
                    preview = packet.s
                case "laptop_request":
                    syncPreview(force: true)
                default: break
                }
            }
        }
        .onDisappear {
            if let id = packetID { link.stopListening(id) }
        }
    }

    private var editor: some View {
        VStack(spacing: 8) {
            HStack {
                Text("БЛОКНОТ").font(.system(size: 9, weight: .bold)).foregroundColor(DuoTheme.cyan)
                Spacer()
                Text("\(text.count) симв.").font(.system(size: 9)).foregroundColor(.white.opacity(0.4))
                Button {
                    text = ""
                    caret = 0
                    link.send(DuoPacket(t: "laptop_clear"), reliable: true)
                } label: {
                    Image(systemName: "trash").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundColor(.white.opacity(0.5))
            }
            .padding(.horizontal, 12).padding(.top, 8)

            TextEditor(text: $text)
                .font(.system(size: 15, design: .monospaced))
                .scrollContentBackgroundHiddenCompat()
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
                .padding(.horizontal, 10)
                .onChange(of: text) { _ in
                    syncPreview(force: false)
                }
            Text("Печатайте здесь — клавиатура на втором iPhone")
                .font(.system(size: 9)).foregroundColor(.white.opacity(0.35))
                .padding(.bottom, 6)
        }
    }

    private var keyboard: some View {
        VStack(spacing: 8) {
            HStack {
                Text("DUO KEYS").font(.system(size: 9, weight: .bold)).foregroundColor(DuoTheme.magenta)
                Spacer()
                Text(preview.isEmpty ? "…" : String(preview.suffix(40)))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.4))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12).padding(.top, 6)

            trackpad
                .frame(height: 92)
                .padding(.horizontal, 10)

            VStack(spacing: 5) {
                ForEach(0..<rows.count, id: \.self) { rowIndex in
                    HStack(spacing: 4) {
                        ForEach(rows[rowIndex], id: \.self) { key in
                            keyButton(key)
                        }
                    }
                }
                HStack(spacing: 5) {
                    actionKey("⌫", color: DuoTheme.amber) { backspace() }
                    actionKey("␣", color: DuoTheme.cyan) { insert(" ") }
                    actionKey("↩", color: DuoTheme.lime) { insert("\n"); link.send(DuoPacket(t: "laptop_newline"), reliable: true) }
                    actionKey("←", color: .white) { move(-1) }
                    actionKey("→", color: .white) { move(1) }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 8)
        }
    }

    private var trackpad: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                VStack(spacing: 4) {
                    Image(systemName: "hand.draw").foregroundColor(.white.opacity(0.3))
                    Text("Трекпад · тап = Enter").font(.system(size: 9)).foregroundColor(.white.opacity(0.3))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        let dx = value.translation.width
                        if abs(dx) > 26 {
                            move(dx > 0 ? 1 : -1)
                        }
                    }
                    .onEnded { value in
                        if abs(value.translation.width) < 6 && abs(value.translation.height) < 6 {
                            insert("\n")
                            link.send(DuoPacket(t: "laptop_newline"), reliable: true)
                        }
                    }
            )
        }
    }

    private func keyButton(_ key: String) -> some View {
        Button {
            insert(key)
        } label: {
            Text(key.uppercased())
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.09)))
                .foregroundColor(.white.opacity(0.9))
        }
        .buttonStyle(.plain)
    }

    private func actionKey(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(RoundedRectangle(cornerRadius: 8).fill(color.opacity(0.18)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.4), lineWidth: 1))
                .foregroundColor(color)
        }
        .buttonStyle(.plain)
    }

    private func insert(_ chunk: String) {
        var chars = Array(text)
        let safe = min(caret, chars.count)
        chars.insert(contentsOf: Array(chunk), at: safe)
        text = String(chars)
        caret = safe + chunk.count
        if !isEditor {
            link.send(DuoPacket(t: "laptop_key", s: chunk), reliable: true)
        } else {
            syncPreview(force: true)
        }
    }

    private func backspace() {
        var chars = Array(text)
        let safe = min(caret, chars.count)
        if safe > 0 {
            chars.remove(at: safe - 1)
            text = String(chars)
            caret = safe - 1
        }
        if isEditor {
            syncPreview(force: true)
        } else {
            link.send(DuoPacket(t: "laptop_backspace"), reliable: true)
        }
    }

    private func move(_ delta: Int) {
        caret = min(max(0, caret + delta), text.count)
        if !isEditor { link.send(DuoPacket(t: "laptop_move", i: delta)) }
    }

    private func syncPreview(force: Bool) {
        guard isEditor else { return }
        guard force || Date().timeIntervalSince(lastSync) > 0.35 else { return }
        lastSync = Date()
        link.send(DuoPacket(t: "laptop_sync", s: text), reliable: false)
    }
}

extension View {
    @ViewBuilder
    func scrollContentBackgroundHiddenCompat() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

// MARK: - 7. StandBy

struct StandbyDuoView: View {
    @EnvironmentObject var link: DuoLink
    @State private var seconds = 0
    @State private var running = false
    @State private var timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var stopwatch: Double = 0
    @State private var swRunning = false
    @State private var swTimer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if link.role == .left { clockSide } else { utilitySide }
        }
        .onReceive(timer) { _ in
            if running && seconds > 0 {
                seconds -= 1
                link.send(DuoPacket(t: "sb_timer", i: seconds, f: running), reliable: true)
                if seconds == 0 { running = false }
            }
        }
        .onReceive(swTimer) { _ in
            if swRunning { stopwatch += 0.1 }
        }
    }

    private var clockSide: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let comps = Calendar.current.dateComponents([.hour, .minute, .second], from: context.date)
            VStack(spacing: 10) {
                HStack(spacing: 2) {
                    flipPair(comps.hour ?? 0)
                    Text(":")
                        .font(.system(size: 46, weight: .thin, design: .rounded))
                        .foregroundColor(.white.opacity(0.35))
                    flipPair(comps.minute ?? 0)
                }
                Text(String(format: "%02d", comps.second ?? 0))
                    .font(.system(size: 22, weight: .light, design: .monospaced))
                    .foregroundColor(DuoTheme.amber)
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 12)).foregroundColor(.white.opacity(0.5))
                Spacer()
                Text("Duo StandBy").font(.system(size: 10, weight: .bold)).foregroundColor(.white.opacity(0.25))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func flipPair(_ value: Int) -> some View {
        Text(String(format: "%02d", value))
            .font(.system(size: 70, weight: .heavy, design: .rounded))
            .foregroundColor(.white)
            .minimumScaleFactor(0.4)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.08), lineWidth: 1))
            )
    }

    private var utilitySide: some View {
        ScrollView {
            VStack(spacing: 10) {
                monthCard
                timerCard
                stopwatchCard
            }
            .padding(10)
        }
    }

    private var monthCard: some View {
        VStack(spacing: 6) {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let cal = Calendar.current
                let comps = cal.dateComponents([.year, .month], from: context.date)
                let first = cal.date(from: comps) ?? context.date
                let days = cal.range(of: .day, in: .month, for: first)?.count ?? 30
                let weekday = (cal.component(.weekday, from: first) + 5) % 7
                VStack(spacing: 5) {
                    HStack {
                        Text(context.date.formatted(.dateTime.month(.wide).year()))
                            .font(.system(size: 13, weight: .bold))
                        Spacer()
                        Text("DUO CAL").font(.system(size: 8)).foregroundColor(.white.opacity(0.4))
                    }
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 3) {
                        ForEach(["П", "В", "С", "Ч", "П", "С", "В"], id: \.self) { day in
                            Text(day).font(.system(size: 8)).foregroundColor(.white.opacity(0.35))
                        }
                        ForEach(0..<weekday, id: \.self) { index in
                            Text("").frame(height: 16)
                        }
                        ForEach(1...days, id: \.self) { day in
                            Text("\(day)")
                                .font(.system(size: 9))
                                .frame(height: 16)
                                .frame(maxWidth: .infinity)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(cal.component(.day, from: context.date) == day
                                              ? DuoTheme.amber.opacity(0.35) : Color.clear)
                                )
                        }
                    }
                }
            }
        }
        .duoCard()
    }

    private var timerCard: some View {
        VStack(spacing: 8) {
            Text("ТАЙМЕР").font(.system(size: 9, weight: .bold)).foregroundColor(DuoTheme.cyan)
            Text(String(format: "%02d:%02d", seconds / 60, seconds % 60))
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            HStack(spacing: 8) {
                Button("+5 мин") { seconds += 300; sendTimer() }.buttonStyle(ChipStyle(tint: DuoTheme.cyan))
                Button("+1 мин") { seconds += 60; sendTimer() }.buttonStyle(ChipStyle(tint: DuoTheme.cyan))
                Button(running ? "Пауза" : "Старт") {
                    running.toggle()
                    sendTimer()
                }.buttonStyle(ChipStyle(tint: running ? DuoTheme.amber : DuoTheme.lime))
                Button("Сброс") { seconds = 0; running = false; sendTimer() }
                    .buttonStyle(ChipStyle(tint: .white))
            }
        }
        .duoCard()
    }

    private var stopwatchCard: some View {
        VStack(spacing: 8) {
            Text("СЕКУНДОМЕР").font(.system(size: 9, weight: .bold)).foregroundColor(DuoTheme.magenta)
            Text(String(format: "%02d:%05.2f", Int(stopwatch) / 60, stopwatch.truncatingRemainder(dividingBy: 60)))
                .font(.system(size: 30, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
            HStack(spacing: 8) {
                Button(swRunning ? "Стоп" : "Пуск") { swRunning.toggle() }
                    .buttonStyle(ChipStyle(tint: swRunning ? DuoTheme.amber : DuoTheme.lime))
                Button("Круг") { link.pushText(String(format: "%.2f", stopwatch)) }
                    .buttonStyle(ChipStyle(tint: DuoTheme.cyan))
                Button("Сброс") { stopwatch = 0; swRunning = false }
                    .buttonStyle(ChipStyle(tint: .white))
            }
        }
        .duoCard()
    }

    private func sendTimer() {
        link.send(DuoPacket(t: "sb_timer", i: seconds, f: running), reliable: true)
    }
}

struct ChipStyle: ButtonStyle {
    var tint: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Capsule().fill(tint.opacity(configuration.isPressed ? 0.35 : 0.18)))
            .overlay(Capsule().stroke(tint.opacity(0.4), lineWidth: 1))
            .foregroundColor(tint)
    }
}

// MARK: - 8. Beatmaker

struct BeatmakerDuoView: View {
    @EnvironmentObject var link: DuoLink
    @State private var pulse: Double = 0
    @State private var activePad: Int = -1
    @State private var packetID: UUID?

    private let freqs: [Double] = [130.81, 146.83, 164.81, 174.61, 196.0, 220.0, 246.94, 261.63,
                                   293.66, 329.63, 349.23, 392.0, 440.0, 493.88, 523.25, 587.33]
    private let baseIndex = 0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                VStack(spacing: 8) {
                    header
                    HStack(alignment: .top, spacing: 0) {
                        padGrid(geo: geo)
                    }
                    waveStrip
                }
                .padding(10)
                if activePad >= 0 {
                    RoundedRectangle(cornerRadius: 0)
                        .stroke(DuoTheme.magenta.opacity(pulse * 0.8), lineWidth: 3)
                        .allowsHitTesting(false)
                }
            }
        }
        .onAppear {
            DuoSynth.shared.start()
            packetID = link.listen { packet in
                if packet.t == "pad" {
                    activePad = packet.i
                    withAnimation(.easeOut(duration: 0.4)) { pulse = 1 }
                    pulse = 0.2
                    if packet.f { DuoSynth.shared.play(freq: freqs[min(packet.i, freqs.count - 1)]) }
                }
            }
        }
        .onDisappear {
            if let id = packetID { link.stopListening(id) }
        }
    }

    private var header: some View {
        HStack {
            Text("DUO BEATMAKER").font(.system(size: 10, weight: .heavy)).foregroundColor(DuoTheme.magenta)
            Spacer()
            Text(link.role == .left ? "ПЭДЫ 1–8" : "ПЭДЫ 9–16")
                .font(.system(size: 9)).foregroundColor(.white.opacity(0.45))
        }
    }

    private func padGrid(geo: GeometryProxy) -> some View {
        let start = link.role == .left ? 0 : 8
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 8) {
            ForEach(start..<(start + 8), id: \.self) { index in
                Button {
                    hit(index)
                } label: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(
                                LinearGradient(colors: [DuoTheme.magenta.opacity(activePad == index ? 0.75 : 0.22),
                                                        DuoTheme.violet.opacity(activePad == index ? 0.5 : 0.12)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)
                            )
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(DuoTheme.magenta.opacity(activePad == index ? 1 : 0.35), lineWidth: 1)
                        VStack(spacing: 2) {
                            Text("\(index + 1)").font(.system(size: 18, weight: .heavy, design: .rounded))
                            Text(noteName(index)).font(.system(size: 8)).foregroundColor(.white.opacity(0.5))
                        }
                        .foregroundColor(.white)
                    }
                    .frame(height: max(44, (geo.size.height - 130) / 4))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var waveStrip: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.06))
                Capsule()
                    .fill(LinearGradient(colors: [DuoTheme.cyan, DuoTheme.magenta],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(4, geo.size.width * CGFloat(pulse)))
            }
        }
        .frame(height: 6)
    }

    private func noteName(_ index: Int) -> String {
        let names = ["C3", "D3", "E3", "F3", "G3", "A3", "B3", "C4",
                     "D4", "E4", "F4", "G4", "A4", "B4", "C5", "D5"]
        return names[min(index, names.count - 1)]
    }

    private func hit(_ index: Int) {
        DuoSynth.shared.play(freq: freqs[min(index, freqs.count - 1)])
        activePad = index
        pulse = 1
        withAnimation(.easeOut(duration: 0.5)) { pulse = 0.15 }
        link.send(DuoPacket(t: "pad", i: index, f: false))
    }
}

// MARK: - 9. Синхронный свет

enum LightMode: String, CaseIterable, Identifiable {
    case strobe, wave, mic
    var id: String { rawValue }
    var title: String { self == .strobe ? "Стробоскоп" : (self == .wave ? "Волна" : "Под музыку") }
}

struct LightSyncDuoView: View {
    @EnvironmentObject var link: DuoLink
    @ObservedObject private var mic = DuoMic.shared
    @State private var mode: LightMode = .strobe
    @State private var bpm: Double = 120
    @State private var phase: Double = 0
    @State private var lit = false
    @State private var packetID: UUID?
    @State private var timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()
    @State private var lastBeat = Date()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LinearGradient(colors: [tint.opacity(brightness), tint.opacity(brightness * 0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            VStack(spacing: 16) {
                Text("DUO LIGHT SYNC")
                    .font(.system(size: 12, weight: .heavy))
                    .foregroundColor(.white.opacity(0.7))
                Text(mode.title).font(.system(size: 30, weight: .black, design: .rounded))
                    .foregroundColor(.white)
                HStack(spacing: 8) {
                    ForEach(LightMode.allCases) { item in
                        Button(item.title) {
                            mode = item
                            if item == .mic { mic.start() } else { mic.stop() }
                            link.send(DuoPacket(t: "light_mode", i: item == .strobe ? 0 : (item == .wave ? 1 : 2)),
                                      reliable: true)
                        }
                        .buttonStyle(ChipStyle(tint: mode == item ? DuoTheme.violet : .white))
                    }
                }
                if mode == .strobe {
                    HStack(spacing: 10) {
                        Text("\(Int(bpm)) BPM").font(.system(size: 12, design: .monospaced))
                        Slider(value: $bpm, in: 60...200, step: 1).frame(width: 160)
                            .onChange(of: bpm) { value in
                                link.send(DuoPacket(t: "light_bpm", d: [value]), reliable: true)
                            }
                    }
                }
                Text(statusLine).font(.system(size: 10)).foregroundColor(.white.opacity(0.6))
                Spacer()
            }
            .padding(.top, 20)
        }
        .onAppear {
            packetID = link.listen { packet in
                switch packet.t {
                case "light_beat":
                    beat(index: packet.i)
                case "light_mode":
                    mode = packet.i == 0 ? .strobe : (packet.i == 1 ? .wave : .mic)
                case "light_bpm":
                    bpm = packet.d.first ?? 120
                default: break
                }
            }
        }
        .onDisappear {
            mic.stop()
            DuoTorch.set(false)
            if let id = packetID { link.stopListening(id) }
        }
        .onReceive(timer) { date in
            step(date: date)
        }
    }

    private var tint: Color {
        switch mode {
        case .strobe: return DuoTheme.violet
        case .wave: return DuoTheme.cyan
        case .mic: return DuoTheme.magenta
        }
    }

    private var brightness: Double {
        switch mode {
        case .strobe: return lit ? 1.0 : 0.05
        case .wave: return 0.15 + 0.85 * abs(sin(phase * .pi))
        case .mic: return 0.1 + 0.9 * mic.level
        }
    }

    private var statusLine: String {
        switch mode {
        case .strobe: return "LED-вспышка и экран в такт \(Int(bpm)) BPM"
        case .wave: return "Бегущая волна с левого телефона на правый"
        case .mic: return String(format: "Микрофон: %.0f%%", mic.level * 100)
        }
    }

    private func beat(index: Int) {
        lit = true
        DuoTorch.set(true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            lit = false
            DuoTorch.set(false)
        }
        phase = Double(index % 2)
    }

    private func step(date: Date) {
        switch mode {
        case .strobe:
            let interval = 60.0 / max(60, bpm)
            if date.timeIntervalSince(lastBeat) >= interval {
                lastBeat = date
                lit.toggle()
                DuoTorch.set(lit)
                if link.role == .left {
                    link.send(DuoPacket(t: "light_beat", i: lit ? 1 : 0))
                }
            }
        case .wave:
            phase += 0.02
            if phase > 1 { phase = 0 }
            if link.role == .left {
                link.send(DuoPacket(t: "light_phase", d: [phase]))
            }
        case .mic:
            if link.role == .left {
                link.send(DuoPacket(t: "light_level", d: [mic.level]))
            }
        }
    }
}

// MARK: - 10. Gravity Sand

struct SandParticle {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
}

final class SandWorld: ObservableObject {
    @Published var particles: [SandParticle] = []
    var tiltGX: Double = 0
    var tiltGY: Double = 0
    private var seeded = false

    func seed() {
        guard !seeded else { return }
        seeded = true
        var list: [SandParticle] = []
        for _ in 0..<140 {
            list.append(SandParticle(x: Double.random(in: 0.2...1.8),
                                     y: Double.random(in: 0.15...0.85),
                                     vx: Double.random(in: -0.03...0.03),
                                     vy: Double.random(in: -0.03...0.03)))
        }
        particles = list
    }

    func step(dt: Double) {
        guard !particles.isEmpty else { return }
        let ax = tiltGX * 1.7
        let ay = tiltGY * 1.7
        for i in particles.indices {
            particles[i].vx = (particles[i].vx + ax * dt) * 0.985
            particles[i].vy = (particles[i].vy + ay * dt) * 0.985
            particles[i].x += particles[i].vx * dt
            particles[i].y += particles[i].vy * dt
            if particles[i].y < 0.01 { particles[i].y = 0.01; particles[i].vy = -particles[i].vy * 0.6 }
            if particles[i].y > 0.99 { particles[i].y = 0.99; particles[i].vy = -particles[i].vy * 0.6 }
            if particles[i].x < 0.01 { particles[i].x = 0.01; particles[i].vx = -particles[i].vx * 0.6 }
            if particles[i].x > 1.99 { particles[i].x = 1.99; particles[i].vx = -particles[i].vx * 0.6 }
        }
    }

    func pack() -> [Double] {
        var out: [Double] = []
        for p in particles.prefix(160) {
            out.append(p.x)
            out.append(p.y)
        }
        return out
    }

    func unpack(_ values: [Double]) {
        var list: [SandParticle] = []
        var i = 0
        while i + 1 < values.count {
            list.append(SandParticle(x: values[i], y: values[i + 1],
                                     vx: 0, vy: 0))
            i += 2
        }
        particles = list
    }
}

struct GravityDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var world = SandWorld()
    @StateObject private var tilt = DuoTilt.shared
    @State private var packetID: UUID?
    @State private var timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                LinearGradient(colors: [Color(red: 0.08, green: 0.06, blue: 0.04),
                                        Color(red: 0.03, green: 0.02, blue: 0.02)],
                               startPoint: .top, endPoint: .bottom)
                Canvas { context, size in
                    for particle in world.particles {
                        let localX = duoLocalX(particle.x, link.role ?? .left)
                        guard localX >= 0, localX <= 1 else { continue }
                        let rect = CGRect(x: CGFloat(localX) * size.width - 2,
                                          y: CGFloat(particle.y) * size.height - 2,
                                          width: 4, height: 4)
                        context.fill(Path(ellipseIn: rect), with: .color(grainColor(particle)))
                    }
                }
                if link.role == .left {
                    Rectangle()
                        .fill(LinearGradient(colors: [.clear, DuoTheme.cyan.opacity(0.25), .clear],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 3)
                        .position(x: geo.size.width - 2, y: geo.size.height / 2)
                }
            }
        }
        .onAppear {
            world.seed()
            tilt.start()
            packetID = link.listen { packet in
                guard packet.t == "sand" else { return }
                if packet.s == "state" { world.unpack(packet.d) }
                if packet.s == "tilt" { world.tiltGX = packet.d.first ?? 0; world.tiltGY = packet.d.count > 1 ? packet.d[1] : 0 }
            }
        }
        .onDisappear {
            tilt.stop()
            if let id = packetID { link.stopListening(id) }
        }
        .onReceive(timer) { _ in
            if link.role == .left {
                world.tiltGX = tilt.gx
                world.tiltGY = tilt.gy
                world.step(dt: 1.0 / 60.0)
                link.send(DuoPacket(t: "sand", s: "state", d: world.pack()))
            } else {
                link.send(DuoPacket(t: "sand", s: "tilt", d: [tilt.gx, tilt.gy]))
                world.step(dt: 1.0 / 60.0)
            }
        }
    }

    private func grainColor(_ p: SandParticle) -> Color {
        let speed = min(1.0, abs(p.vx) + abs(p.vy))
        return Color(red: 0.95, green: 0.78 - speed * 0.2, blue: 0.45 + speed * 0.2)
    }
}

// MARK: - 11. Лабиринт

final class MazeWorld: ObservableObject {
    @Published var ballX: Double = 0.1
    @Published var ballY: Double = 0.5
    @Published var won = false
    @Published var seconds: Double = 0

    private(set) var walls: [CGRect] = []
    private var vx: Double = 0
    private var vy: Double = 0
    private let radius: Double = 0.012
    private let goal = CGPoint(x: 1.9, y: 0.5)

    init() { build() }

    func reset() {
        ballX = 0.1; ballY = 0.5; vx = 0; vy = 0; won = false; seconds = 0
    }

    private func build() {
        let cols = 10, rows = 8
        let cw = 2.0 / Double(cols)
        let ch = 1.0 / Double(rows)
        var visited = Array(repeating: Array(repeating: false, count: rows), count: cols)
        var stack: [(Int, Int)] = [(0, 4)]
        visited[0][4] = true
        var passages: Set<String> = []
        while let (cx, cy) = stack.last {
            var neighbours: [(Int, Int)] = []
            let candidates = [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)]
            for (nx, ny) in candidates {
                if nx >= 0, nx < cols, ny >= 0, ny < rows, !visited[nx][ny] {
                    neighbours.append((nx, ny))
                }
            }
            if neighbours.isEmpty {
                stack.removeLast()
            } else {
                let next = neighbours[Int.random(in: 0..<neighbours.count)]
                visited[next.0][next.1] = true
                let a = "\(min(cx, next.0))-\(min(cy, next.1))-\(max(cx, next.0))-\(max(cy, next.1))"
                passages.insert(a)
                stack.append(next)
            }
        }
        var rects: [CGRect] = []
        let t = 0.006
        for cx in 0..<cols {
            for cy in 0..<rows {
                let x0 = Double(cx) * cw
                let y0 = Double(cy) * ch
                // восточная стена
                if cx < cols - 1 {
                    let key = "\(cx)-\(cy)-\(cx + 1)-\(cy)"
                    if !passages.contains(key) {
                        rects.append(CGRect(x: x0 + cw - t / 2, y: y0, width: t, height: ch))
                    }
                }
                // южная стена
                if cy < rows - 1 {
                    let key = "\(cx)-\(cy)-\(cx)-\(cy + 1)"
                    if !passages.contains(key) {
                        rects.append(CGRect(x: x0, y: y0 + ch - t / 2, width: cw, height: t))
                    }
                }
            }
        }
        rects.append(CGRect(x: 0, y: 0, width: 2.0, height: t))
        rects.append(CGRect(x: 0, y: 1.0 - t, width: 2.0, height: t))
        rects.append(CGRect(x: 0, y: 0, width: t, height: 1.0))
        rects.append(CGRect(x: 2.0 - t, y: 0, width: t, height: 1.0))
        walls = rects
    }

    var goalPoint: CGPoint { goal }

    func step(dt: Double, gx: Double, gy: Double) {
        guard !won else { return }
        seconds += dt
        vx = (vx + gx * 2.4 * dt) * 0.995
        vy = (vy + gy * 2.4 * dt) * 0.995
        vx = max(-0.9, min(0.9, vx))
        vy = max(-0.9, min(0.9, vy))
        ballX += vx * dt
        ballY += vy * dt

        for wall in walls {
            let nearestX = max(Double(wall.minX), min(ballX, Double(wall.maxX)))
            let nearestY = max(Double(wall.minY), min(ballY, Double(wall.maxY)))
            let dx = ballX - nearestX
            let dy = ballY - nearestY
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < radius {
                if dist == 0 {
                    ballX = Double(wall.midX)
                    ballY = Double(wall.minY) - radius
                    vy = -abs(vy)
                } else {
                    let push = (radius - dist) + 0.0005
                    ballX += dx / dist * push
                    ballY += dy / dist * push
                    if abs(dx) > abs(dy) { vx = -vx * 0.6 } else { vy = -vy * 0.6 }
                }
            }
        }

        let dx = ballX - Double(goal.x)
        let dy = ballY - Double(goal.y)
        if (dx * dx + dy * dy).squareRoot() < 0.04 { won = true }
    }
}

struct MazeDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var world = MazeWorld()
    @StateObject private var tilt = DuoTilt.shared
    @State private var packetID: UUID?
    @State private var timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    @State private var remoteGX: Double = 0
    @State private var remoteGY: Double = 0

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { geo in
                Canvas { ctx, size in
                    let scaleX = size.width
                    let scaleY = size.height
                    for wall in world.walls {
                        let localX = duoLocalX(Double(wall.minX), link.role ?? .left)
                        let rect = CGRect(x: CGFloat(localX) * scaleX,
                                          y: wall.minY * scaleY,
                                          width: wall.width * scaleX,
                                          height: wall.height * scaleY)
                        if rect.maxX < 0 || rect.minX > size.width { continue }
                        ctx.fill(Path(rect), with: .color(Color.white.opacity(0.16)))
                    }
                    let gx = duoLocalX(Double(world.goalPoint.x), link.role ?? .left)
                    let goalRect = CGRect(x: CGFloat(gx) * scaleX - 12, y: world.goalPoint.y * scaleY - 12,
                                          width: 24, height: 24)
                    ctx.fill(Path(ellipseIn: goalRect), with: .color(DuoTheme.lime.opacity(0.85)))

                    let bx = duoLocalX(world.ballX, link.role ?? .left)
                    let ballRect = CGRect(x: CGFloat(bx) * scaleX - 7, y: CGFloat(world.ballY) * scaleY - 7,
                                          width: 14, height: 14)
                    ctx.fill(Path(ellipseIn: ballRect), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: ballRect.insetBy(dx: -2, dy: -2)),
                               with: .color(DuoTheme.cyan.opacity(0.7)), lineWidth: 1)
                }
            }
        }
        .onAppear {
            tilt.start()
            packetID = link.listen { packet in
                guard packet.t == "maze" else { return }
                if packet.s == "state" {
                    world.ballX = packet.d.first ?? 0
                    world.ballY = packet.d.count > 1 ? packet.d[1] : 0
                    world.won = packet.d.count > 2 && packet.d[2] > 0.5
                }
                if packet.s == "tilt" {
                    remoteGX = packet.d.first ?? 0
                    remoteGY = packet.d.count > 1 ? packet.d[1] : 0
                }
                if packet.s == "reset" { world.reset() }
            }
        }
        .onDisappear {
            tilt.stop()
            if let id = packetID { link.stopListening(id) }
        }
        .onReceive(timer) { _ in
            if link.role == .left {
                world.step(dt: 1.0 / 60.0, gx: tilt.gx + remoteGX, gy: tilt.gy + remoteGY)
                link.send(DuoPacket(t: "maze", s: "state",
                                    d: [world.ballX, world.ballY, world.won ? 1 : 0]))
            } else {
                link.send(DuoPacket(t: "maze", s: "tilt", d: [tilt.gx, tilt.gy]))
            }
        }
    }

    private var header: some View {
        HStack {
            Text("DUO TILT MAZE").font(.system(size: 10, weight: .heavy)).foregroundColor(DuoTheme.lime)
            Spacer()
            Text(world.won ? "ЦЕЛЬ ДОСТИГНУТА" : String(format: "%.1f с", world.seconds))
                .font(.system(size: 10)).foregroundColor(.white.opacity(0.6))
            Button("Рестарт") {
                world.reset()
                link.send(DuoPacket(t: "maze", s: "reset"), reliable: true)
            }
            .buttonStyle(ChipStyle(tint: DuoTheme.cyan))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
    }
}

// MARK: - 12. Аэрохоккей

final class HockeyWorld: ObservableObject {
    @Published var puckX = 1.0
    @Published var puckY = 0.5
    @Published var leftX = 0.25
    @Published var leftY = 0.5
    @Published var rightX = 1.75
    @Published var rightY = 0.5
    @Published var scoreLeft = 0
    @Published var scoreRight = 0

    var vx = 0.7
    var vy = 0.35
    let puckR = 0.021
    let paddleR = 0.048

    func reset(serveToLeft: Bool) {
        puckX = 1.0
        puckY = 0.5
        vx = serveToLeft ? -0.75 : 0.75
        vy = Double.random(in: -0.4...0.4)
    }

    func step(dt: Double, lTarget: CGPoint?, rTarget: CGPoint?) {
        if let l = lTarget {
            leftX += (Double(l.x) - leftX) * 0.35
            leftY += (Double(l.y) - leftY) * 0.35
        }
        if let r = rTarget {
            rightX += (Double(r.x) - rightX) * 0.35
            rightY += (Double(r.y) - rightY) * 0.35
        }
        leftX = max(paddleR, min(0.97 - paddleR, leftX))
        leftY = max(paddleR, min(1 - paddleR, leftY))
        rightX = max(1.03 + paddleR, min(2 - paddleR, rightX))
        rightY = max(paddleR, min(1 - paddleR, rightY))

        puckX += vx * dt
        puckY += vy * dt

        if puckY < puckR { puckY = puckR; vy = -vy }
        if puckY > 1 - puckR { puckY = 1 - puckR; vy = -vy }

        bounce(paddleX: leftX, paddleY: leftY)
        bounce(paddleX: rightX, paddleY: rightY)

        if puckX < -0.02 {
            scoreRight += 1
            reset(serveToLeft: false)
        }
        if puckX > 2.02 {
            scoreLeft += 1
            reset(serveToLeft: true)
        }
    }

    private func bounce(paddleX: Double, paddleY: Double) {
        let dx = puckX - paddleX
        let dy = puckY - paddleY
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist < puckR + paddleR, dist > 0.0001 else { return }
        let nx = dx / dist
        let ny = dy / dist
        puckX = paddleX + nx * (puckR + paddleR + 0.001)
        puckY = paddleY + ny * (puckR + paddleR + 0.001)
        let speed = max(0.85, (vx * vx + vy * vy).squareRoot() * 1.02)
        vx = nx * speed
        vy = ny * speed
        vx = max(-2.6, min(2.6, vx))
        vy = max(-2.2, min(2.2, vy))
    }
}

struct HockeyDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var world = HockeyWorld()
    @State private var localTouch: CGPoint?
    @State private var remoteTouch: CGPoint?
    @State private var packetID: UUID?
    @State private var timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            scoreBar
            GeometryReader { geo in
                ZStack {
                    field
                    touchLayer(size: geo.size)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let role = link.role ?? .left
                            let lx = Double(value.location.x / max(1, geo.size.width))
                            let ly = Double(value.location.y / max(1, geo.size.height))
                            let wx = role == .left ? lx : lx + 1
                            localTouch = CGPoint(x: wx, y: ly)
                            if role == .right {
                                link.send(DuoPacket(t: "hockey", s: "paddle", d: [wx, ly]))
                            }
                        }
                )
            }
        }
        .onAppear {
            packetID = link.listen { packet in
                guard packet.t == "hockey" else { return }
                switch packet.s {
                case "paddle":
                    remoteTouch = CGPoint(x: packet.d.first ?? 0, y: packet.d.count > 1 ? packet.d[1] : 0)
                case "state":
                    guard packet.d.count >= 10 else { return }
                    world.puckX = packet.d[0]; world.puckY = packet.d[1]
                    world.vx = packet.d[2]; world.vy = packet.d[3]
                    world.leftX = packet.d[4]; world.leftY = packet.d[5]
                    world.rightX = packet.d[6]; world.rightY = packet.d[7]
                    world.scoreLeft = Int(packet.d[8]); world.scoreRight = Int(packet.d[9])
                default: break
                }
            }
        }
        .onDisappear {
            if let id = packetID { link.stopListening(id) }
        }
        .onReceive(timer) { _ in
            guard link.role == .left else { return }
            let l = localTouch
            let r = remoteTouch
            world.step(dt: 1.0 / 60.0, lTarget: l, rTarget: r)
            link.send(DuoPacket(t: "hockey", s: "state",
                                d: [world.puckX, world.puckY, world.vx, world.vy,
                                    world.leftX, world.leftY, world.rightX, world.rightY,
                                    Double(world.scoreLeft), Double(world.scoreRight)]))
        }
    }

    private var scoreBar: some View {
        HStack {
            Text("\(world.scoreLeft)").font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundColor(DuoTheme.cyan)
            Text("DUO AIR HOCKEY").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.4))
            Text("\(world.scoreRight)").font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundColor(DuoTheme.magenta)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .background(Color.black.opacity(0.4))
    }

    private var field: some View {
        Canvas { ctx, size in
            let w = size.width
            let h = size.height
            for row in 0..<10 {
                let rect = CGRect(x: 0, y: CGFloat(row) * h / 10, width: w, height: 1)
                ctx.fill(Path(rect), with: .color(Color.white.opacity(0.05)))
            }
            let role = link.role ?? .left
            // центральная линия
            let seam = CGRect(x: role == .left ? w - 2 : 0, y: 0, width: 2, height: h)
            ctx.fill(Path(seam), with: .color(DuoTheme.cyan.opacity(0.5)))

            // ворота
            let goalTop = h * 0.36
            let goalHeight = h * 0.28
            let goalX = role == .left ? 0.0 : w - 6
            ctx.fill(Path(CGRect(x: goalX, y: goalTop, width: 6, height: goalHeight)),
                     with: .color(DuoTheme.amber.opacity(0.7)))

            let lpx = CGFloat(duoLocalX(world.leftX, role)) * w
            let rpx = CGFloat(duoLocalX(world.rightX, role)) * w
            let pr = CGFloat(world.paddleR) * w
            let paddles: [(CGFloat, CGFloat, Color)] = [
                (lpx, CGFloat(world.leftY) * h, DuoTheme.cyan),
                (rpx, CGFloat(world.rightY) * h, DuoTheme.magenta)
            ]
            for (x, y, color) in paddles {
                let rect = CGRect(x: x - pr, y: y - pr, width: pr * 2, height: pr * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(color.opacity(0.85)))
                ctx.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.5)), lineWidth: 1)
            }
            let puckR = CGFloat(world.puckR) * w
            let puckRect = CGRect(x: CGFloat(duoLocalX(world.puckX, role)) * w - puckR,
                                  y: CGFloat(world.puckY) * h - puckR,
                                  width: puckR * 2, height: puckR * 2)
            ctx.fill(Path(ellipseIn: puckRect), with: .color(.white))
        }
        .background(Color(red: 0.03, green: 0.05, blue: 0.09))
    }

    private func touchLayer(size: CGSize) -> some View {
        Color.clear
    }
}

// MARK: - 13. Пинг-понг

final class PongWorld: ObservableObject {
    @Published var ballX = 1.0
    @Published var ballY = 0.5
    @Published var leftY = 0.5
    @Published var rightY = 0.5
    @Published var scoreLeft = 0
    @Published var scoreRight = 0

    var vx = 0.6
    var vy = 0.4
    let paddleH = 0.22
    let ballR = 0.017
    let paddleW = 0.014

    func reset(toLeft: Bool) {
        ballX = 1.0
        ballY = Double.random(in: 0.25...0.75)
        let speed = min(1.6, 0.62 + Double(scoreLeft + scoreRight) * 0.05)
        vx = (toLeft ? -1 : 1) * speed
        vy = Double.random(in: -0.45...0.45)
    }

    func step(dt: Double, l: Double?, r: Double?) {
        if let l = l { leftY += (l - leftY) * 0.4 }
        if let r = r { rightY += (r - rightY) * 0.4 }
        leftY = max(paddleH / 2, min(1 - paddleH / 2, leftY))
        rightY = max(paddleH / 2, min(1 - paddleH / 2, rightY))

        ballX += vx * dt
        ballY += vy * dt
        if ballY < ballR { ballY = ballR; vy = -vy }
        if ballY > 1 - ballR { ballY = 1 - ballR; vy = -vy }

        if ballX < 0.045, ballX > 0.01, abs(ballY - leftY) < paddleH / 2 + ballR {
            ballX = 0.045
            vx = abs(vx) * 1.05
            vy += (ballY - leftY) * 1.4
        }
        if ballX > 1.955, ballX < 1.99, abs(ballY - rightY) < paddleH / 2 + ballR {
            ballX = 1.955
            vx = -abs(vx) * 1.05
            vy += (ballY - rightY) * 1.4
        }
        if ballX < -0.02 {
            scoreRight += 1
            reset(toLeft: false)
        }
        if ballX > 2.02 {
            scoreLeft += 1
            reset(toLeft: true)
        }
    }
}

struct PongDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var world = PongWorld()
    @State private var localY: Double?
    @State private var remoteY: Double?
    @State private var packetID: UUID?
    @State private var timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(world.scoreLeft)").font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(DuoTheme.lime)
                Spacer()
                Text("DUO PONG").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.4))
                Spacer()
                Text("\(world.scoreRight)").font(.system(size: 24, weight: .heavy, design: .rounded))
                    .foregroundColor(DuoTheme.magenta)
            }
            .padding(.horizontal, 16).padding(.vertical, 4)

            GeometryReader { geo in
                Canvas { ctx, size in
                    let role = link.role ?? .left
                    for i in stride(from: 0, to: 1.0, by: 0.08) {
                        let rect = CGRect(x: size.width / 2 - 1, y: CGFloat(i) * size.height,
                                          width: 2, height: size.height * 0.04)
                        ctx.fill(Path(rect), with: .color(Color.white.opacity(0.18)))
                    }
                    let lx = CGFloat(duoLocalX(0.04, role)) * size.width
                    let rx = CGFloat(duoLocalX(1.96, role)) * size.width
                    let ph = CGFloat(world.paddleH) * size.height
                    ctx.fill(Path(roundedRect: CGRect(x: lx, y: CGFloat(world.leftY) * size.height - ph / 2,
                                                      width: size.width * 0.014, height: ph), cornerRadius: 3),
                             with: .color(DuoTheme.lime))
                    ctx.fill(Path(roundedRect: CGRect(x: rx - size.width * 0.014,
                                                      y: CGFloat(world.rightY) * size.height - ph / 2,
                                                      width: size.width * 0.014, height: ph), cornerRadius: 3),
                             with: .color(DuoTheme.magenta))
                    let br = CGFloat(world.ballR) * size.width * 1.6
                    let ball = CGRect(x: CGFloat(duoLocalX(world.ballX, role)) * size.width - br,
                                      y: CGFloat(world.ballY) * size.height - br,
                                      width: br * 2, height: br * 2)
                    ctx.fill(Path(ellipseIn: ball), with: .color(.white))
                }
                .background(Color(red: 0.02, green: 0.04, blue: 0.05))
                .gesture(
                    DragGesture(minimumDistance: 0).onChanged { value in
                        let y = Double(value.location.y / max(1, geo.size.height))
                        localY = y
                        if link.role == .right {
                            link.send(DuoPacket(t: "pong", s: "paddle", d: [y]))
                        }
                    }
                )
            }
        }
        .onAppear {
            packetID = link.listen { packet in
                guard packet.t == "pong" else { return }
                if packet.s == "paddle" { remoteY = packet.d.first }
                if packet.s == "state", packet.d.count >= 6 {
                    world.ballX = packet.d[0]; world.ballY = packet.d[1]
                    world.vx = packet.d[2]; world.vy = packet.d[3]
                    world.leftY = packet.d[4]; world.rightY = packet.d[5]
                    if packet.d.count >= 8 {
                        world.scoreLeft = Int(packet.d[6]); world.scoreRight = Int(packet.d[7])
                    }
                }
            }
        }
        .onDisappear {
            if let id = packetID { link.stopListening(id) }
        }
        .onReceive(timer) { _ in
            guard link.role == .left else { return }
            world.step(dt: 1.0 / 60.0, l: localY, r: remoteY)
            link.send(DuoPacket(t: "pong", s: "state",
                                d: [world.ballX, world.ballY, world.vx, world.vy,
                                    world.leftY, world.rightY,
                                    Double(world.scoreLeft), Double(world.scoreRight)]))
        }
    }
}

// MARK: - 14. Космическая дуэль

final class SpaceWorld: ObservableObject {
    struct Bullet {
        var x: Double
        var y: Double
        var vx: Double
        var owner: Int // 0 — левый, 1 — правый
    }

    @Published var leftY = 0.5
    @Published var rightY = 0.5
    @Published var bullets: [Bullet] = []
    @Published var hpLeft = 100.0
    @Published var hpRight = 100.0
    @Published var winner: Int = -1
    var cooldownLeft: Double = 0
    var cooldownRight: Double = 0

    func reset() {
        bullets = []
        hpLeft = 100
        hpRight = 100
        winner = -1
        leftY = 0.5
        rightY = 0.5
    }

    func fire(owner: Int) {
        guard winner < 0 else { return }
        if owner == 0 {
            guard cooldownLeft <= 0 else { return }
            cooldownLeft = 0.28
            bullets.append(Bullet(x: 0.14, y: leftY, vx: 1.05, owner: 0))
        } else {
            guard cooldownRight <= 0 else { return }
            cooldownRight = 0.28
            bullets.append(Bullet(x: 1.86, y: rightY, vx: -1.05, owner: 1))
        }
    }

    func step(dt: Double) {
        cooldownLeft = max(0, cooldownLeft - dt)
        cooldownRight = max(0, cooldownRight - dt)
        guard winner < 0 else { return }
        for i in bullets.indices {
            bullets[i].x += bullets[i].vx * dt
            if bullets[i].owner == 0, bullets[i].x > 1.9, abs(bullets[i].y - rightY) < 0.075 {
                hpRight = max(0, hpRight - 12)
                bullets[i].x = 3
            }
            if bullets[i].owner == 1, bullets[i].x < 0.1, abs(bullets[i].y - leftY) < 0.075 {
                hpLeft = max(0, hpLeft - 12)
                bullets[i].x = -1
            }
        }
        bullets.removeAll { $0.x < -0.5 || $0.x > 2.5 }
        if hpLeft <= 0 { winner = 1 }
        if hpRight <= 0 { winner = 0 }
    }
}

struct SpaceDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var world = SpaceWorld()
    @State private var localY: Double = 0.5
    @State private var remoteY: Double = 0.5
    @State private var packetID: UUID?
    @State private var timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Canvas { ctx, size in
                    let role = link.role ?? .left
                    for i in 0..<40 {
                        let x = CGFloat((i * 37) % 100) / 100 * size.width
                        let y = CGFloat((i * 61) % 100) / 100 * size.height
                        ctx.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.5, height: 1.5)),
                                 with: .color(.white.opacity(0.35)))
                    }
                    // корабли
                    let ly = CGFloat(duoLocalX(0.08, role)) * size.width
                    let ry = CGFloat(duoLocalX(1.92, role)) * size.width
                    ship(&ctx, x: ly, y: CGFloat(world.leftY) * size.height, color: DuoTheme.cyan, mirrored: false)
                    ship(&ctx, x: ry, y: CGFloat(world.rightY) * size.height, color: DuoTheme.magenta, mirrored: true)
                    // пули
                    for bullet in world.bullets {
                        let bx = CGFloat(duoLocalX(bullet.x, role)) * size.width
                        let rect = CGRect(x: bx - 4, y: CGFloat(bullet.y) * size.height - 2, width: 8, height: 4)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 2),
                                 with: .color(bullet.owner == 0 ? DuoTheme.cyan : DuoTheme.magenta))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let y = max(0.06, min(0.94, Double(value.location.y / max(1, geo.size.height))))
                            localY = y
                            world.setY(role: link.role ?? .left, y: y)
                            if link.role == .right {
                                link.send(DuoPacket(t: "space", s: "y", d: [y]))
                            }
                        }
                        .onEnded { _ in
                            world.fire(owner: link.role == .left ? 0 : 1)
                            link.send(DuoPacket(t: "space", s: "fire"), reliable: true)
                        }
                )
            }
            VStack {
                hpBars
                Spacer()
                HStack {
                    Button("ОГОНЬ") {
                        world.fire(owner: link.role == .left ? 0 : 1)
                        link.send(DuoPacket(t: "space", s: "fire"), reliable: true)
                    }
                    .buttonStyle(ChipStyle(tint: DuoTheme.magenta))
                    Button("Рестарт") {
                        world.reset()
                        link.send(DuoPacket(t: "space", s: "reset"), reliable: true)
                    }
                    .buttonStyle(ChipStyle(tint: .white))
                }
                .padding(.bottom, 8)
            }
            if world.winner >= 0 {
                Text(world.winner == (link.role == .left ? 0 : 1) ? "ПОБЕДА" : "ПОРАЖЕНИЕ")
                    .font(.system(size: 34, weight: .black, design: .rounded))
                    .foregroundColor(world.winner == 0 ? DuoTheme.cyan : DuoTheme.magenta)
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color.black.opacity(0.7)))
            }
        }
        .onAppear {
            packetID = link.listen { packet in
                guard packet.t == "space" else { return }
                switch packet.s {
                case "y":
                    remoteY = packet.d.first ?? 0.5
                    world.setY(role: link.role?.opposite ?? .right, y: remoteY)
                case "fire":
                    world.fire(owner: link.role == .left ? 1 : 0)
                case "reset":
                    world.reset()
                case "state":
                    guard packet.d.count >= 5 else { return }
                    world.leftY = packet.d[0]; world.rightY = packet.d[1]
                    world.hpLeft = packet.d[2]; world.hpRight = packet.d[3]
                    var list: [SpaceWorld.Bullet] = []
                    var i = 4
                    while i + 2 < packet.d.count - 1 {
                        list.append(SpaceWorld.Bullet(x: packet.d[i], y: packet.d[i + 1],
                                                      vx: 0, owner: Int(packet.d[i + 2])))
                        i += 3
                    }
                    world.bullets = list
                    world.winner = Int(packet.d[packet.d.count - 1])
                default: break
                }
            }
        }
        .onDisappear {
            if let id = packetID { link.stopListening(id) }
        }
        .onReceive(timer) { _ in
            if link.role == .left {
                world.step(dt: 1.0 / 60.0)
                var d: [Double] = [world.leftY, world.rightY, world.hpLeft, world.hpRight]
                for bullet in world.bullets.prefix(30) {
                    d.append(bullet.x); d.append(bullet.y); d.append(Double(bullet.owner))
                }
                d.append(Double(world.winner))
                link.send(DuoPacket(t: "space", s: "state", d: d))
            } else {
                world.step(dt: 1.0 / 60.0)
            }
        }
    }

    private func ship(_ ctx: inout GraphicsContext, x: CGFloat, y: CGFloat, color: Color, mirrored: Bool) {
        var path = Path()
        path.move(to: CGPoint(x: x + (mirrored ? -14 : 14), y: y))
        path.addLine(to: CGPoint(x: x + (mirrored ? 10 : -10), y: y - 11))
        path.addLine(to: CGPoint(x: x + (mirrored ? 10 : -10), y: y + 11))
        path.closeSubpath()
        ctx.fill(path, with: .color(color))
        ctx.stroke(path, with: .color(.white.opacity(0.6)), lineWidth: 1)
    }

    private var hpBars: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Text("HP \(Int(world.hpLeft))")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(DuoTheme.cyan)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(DuoTheme.cyan).frame(width: geo.size.width * CGFloat(world.hpLeft / 100))
                    }
                }
                .frame(height: 6)
                GeometryReader { geo in
                    ZStack(alignment: .trailing) {
                        Capsule().fill(Color.white.opacity(0.1))
                        Capsule().fill(DuoTheme.magenta).frame(width: geo.size.width * CGFloat(world.hpRight / 100))
                    }
                }
                .frame(height: 6)
                Text("HP \(Int(world.hpRight))")
                    .font(.system(size: 9, weight: .bold)).foregroundColor(DuoTheme.magenta)
            }
        }
        .padding(.horizontal, 12).padding(.top, 6)
    }
}

extension SpaceWorld {
    func setY(role: DuoRole, y: Double) {
        if role == .left { leftY = y } else { rightY = y }
    }
}

// MARK: - 15. Морской бой

final class SeaWorld: ObservableObject {
    @Published var ownFleet: [Bool] = Array(repeating: false, count: 64)
    @Published var ownMarks: [Int] = Array(repeating: 0, count: 64)
    @Published var enemyMarks: [Int] = Array(repeating: 0, count: 64)
    @Published var myTurn = true
    @Published var winner = -1
    @Published var showEnemy = false

    var enemyFleet: [Bool] = Array(repeating: false, count: 64)

    var shipCells: Int { ownFleet.filter { $0 }.count }
    var enemyShipCells: Int { enemyFleet.filter { $0 }.count }
    var hitsOnMe: Int { ownMarks.filter { $0 == 2 }.count }
    var hitsOnEnemy: Int { enemyMarks.filter { $0 == 2 }.count }

    static func randomFleet() -> [Bool] {
        var grid = Array(repeating: false, count: 64)
        let ships = [4, 3, 3, 2, 2, 2, 1, 1, 1, 1]
        for length in ships {
            var placed = false
            var attempts = 0
            while !placed && attempts < 500 {
                attempts += 1
                let horizontal = Bool.random()
                let row = Int.random(in: 0..<8)
                let col = Int.random(in: 0..<8)
                if horizontal && col + length > 8 { continue }
                if !horizontal && row + length > 8 { continue }
                var cells: [Int] = []
                var ok = true
                for step in 0..<length {
                    let r = horizontal ? row : row + step
                    let c = horizontal ? col + step : col
                    let index = r * 8 + c
                    if grid[index] { ok = false }
                    for dr in -1...1 {
                        for dc in -1...1 {
                            let rr = r + dr, cc = c + dc
                            if rr >= 0, rr < 8, cc >= 0, cc < 8, grid[rr * 8 + cc] { ok = false }
                        }
                    }
                    cells.append(index)
                }
                if ok {
                    for cell in cells { grid[cell] = true }
                    placed = true
                }
            }
        }
        return grid
    }
}

struct SeaBattleDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var world = SeaWorld()
    @State private var packetID: UUID?

    private var isHost: Bool { link.role == .left }

    var body: some View {
        VStack(spacing: 6) {
            header
            grid
            Text(status)
                .font(.system(size: 10))
                .foregroundColor(world.myTurn ? DuoTheme.lime : .white.opacity(0.45))
            Text("Корабли: \(world.hitsOnMe)/\(world.shipCells) пробоин у вас · \(world.hitsOnEnemy)/\(world.enemyShipCells) у врага")
                .font(.system(size: 8)).foregroundColor(.white.opacity(0.35))
                .padding(.bottom, 6)
        }
        .onAppear {
            if isHost {
                world.ownFleet = SeaWorld.randomFleet()
                world.enemyFleet = SeaWorld.randomFleet()
                world.myTurn = true
                pushState()
            }
            link.send(DuoPacket(t: "sea", s: "hello"), reliable: true)
            packetID = link.listen { packet in
                guard packet.t == "sea" else { return }
                if packet.s == "hello", isHost { pushState() }
                if packet.s == "shot", isHost { guestShot(packet.i) }
                if packet.s == "state", !isHost { applyState(packet) }
            }
        }
        .onDisappear {
            if let id = packetID { link.stopListening(id) }
        }
        .alert(isPresented: Binding(get: { world.winner >= 0 }, set: { _ in })) {
            Alert(title: Text(winnerText),
                  dismissButton: .default(Text("Заново")) { restart() })
        }
    }

    private var status: String {
        if world.winner >= 0 { return winnerText }
        if !link.connected { return "Нет связи — ход невозможен" }
        return world.myTurn ? "Ваш ход: тапните по морю врага" : "Ход соперника…"
    }

    private var winnerText: String {
        if world.winner < 0 { return "" }
        if world.winner == 2 { return "Ничья" }
        let mine = isHost ? 0 : 1
        return world.winner == mine ? "Победа! Флот врага потоплен" : "Поражение — ваш флот потоплен"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("DUO SEA BATTLE").font(.system(size: 10, weight: .heavy)).foregroundColor(DuoTheme.cyan)
            Spacer()
            Text(isHost ? "ХОСТ" : "ГОСТЬ").font(.system(size: 8)).foregroundColor(.white.opacity(0.4))
            Button(world.showEnemy ? "Моё море" : "Море врага") {
                world.showEnemy.toggle()
            }
            .buttonStyle(ChipStyle(tint: DuoTheme.violet))
        }
        .padding(.horizontal, 10).padding(.top, 4)
    }

    private var grid: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height - 6)
            let cell = side / 8
            VStack(spacing: 2) {
                ForEach(0..<8, id: \.self) { row in
                    HStack(spacing: 2) {
                        ForEach(0..<8, id: \.self) { col in
                            cellView(index: row * 8 + col, size: cell)
                        }
                    }
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func cellView(index: Int, size: CGFloat) -> some View {
        let showOwn = !world.showEnemy
        let hasShip = showOwn && world.ownFleet[index]
        let mark = showOwn ? world.ownMarks[index] : world.enemyMarks[index]
        var fill = Color.white.opacity(0.05)
        if hasShip { fill = DuoTheme.cyan.opacity(0.32) }
        if mark == 1 { fill = Color.white.opacity(0.13) }
        if mark == 2 { fill = DuoTheme.magenta.opacity(0.6) }
        return Button {
            shoot(index: index)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 3).fill(fill)
                RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.08), lineWidth: 0.5)
                if mark == 1 {
                    Circle().fill(Color.white.opacity(0.55)).frame(width: max(3, size * 0.16))
                }
                if mark == 2 {
                    Image(systemName: "xmark")
                        .font(.system(size: max(6, size * 0.38)))
                        .foregroundColor(.white)
                }
            }
            .frame(width: max(8, size - 2), height: max(8, size - 2))
        }
        .buttonStyle(.plain)
        .disabled(showOwn || !world.myTurn || mark != 0 || world.winner >= 0 || !link.connected)
    }

    private func shoot(index: Int) {
        guard world.showEnemy, world.myTurn, world.enemyMarks[index] == 0 else { return }
        if isHost {
            resolve(index: index, shooterIsHost: true)
        } else {
            link.send(DuoPacket(t: "sea", s: "shot", i: index), reliable: true)
            world.enemyMarks[index] = 1
            world.myTurn = false
        }
    }

    private func guestShot(_ index: Int) {
        guard world.winner < 0 else { return }
        guard !world.myTurn else { return }
        resolve(index: index, shooterIsHost: false)
    }

    private func resolve(index: Int, shooterIsHost: Bool) {
        let hit = shooterIsHost ? world.enemyFleet[index] : world.ownFleet[index]
        let result = hit ? 2 : 1
        if shooterIsHost {
            world.enemyMarks[index] = result
            world.myTurn = false
        } else {
            world.ownMarks[index] = result
            world.myTurn = true
        }
        if world.hitsOnEnemy >= world.enemyShipCells { world.winner = 0 }
        if world.hitsOnMe >= world.shipCells { world.winner = 1 }
        pushState()
    }

    private func pushState() {
        guard isHost else { return }
        let fleet = world.enemyFleet.map { $0 ? "1" : "0" }.joined()
        let myMarks = world.ownMarks.map { String($0) }.joined()
        let hisMarks = world.enemyMarks.map { String($0) }.joined()
        let turn = world.myTurn ? 0 : 1
        link.send(DuoPacket(t: "sea",
                            s: "state|\(fleet)|\(hisMarks)|\(myMarks)|\(turn)|\(world.winner)"),
                  reliable: true)
    }

    private func applyState(_ packet: DuoPacket) {
        let parts = packet.s.components(separatedBy: "|")
        guard parts.count >= 6 else { return }
        world.ownFleet = parts[1].map { $0 == "1" }
        world.ownMarks = parts[2].map { Int(String($0)) ?? 0 }.padded64
        world.enemyMarks = parts[3].map { Int(String($0)) ?? 0 }.padded64
        world.myTurn = parts[4] == "1"
        world.winner = Int(parts[5]) ?? -1
    }

    private func restart() {
        if isHost {
            world.ownFleet = SeaWorld.randomFleet()
            world.enemyFleet = SeaWorld.randomFleet()
        }
        world.ownMarks = Array(repeating: 0, count: 64)
        world.enemyMarks = Array(repeating: 0, count: 64)
        world.myTurn = isHost
        world.winner = -1
        pushState()
    }
}

extension Array where Element == Int {
    var padded64: [Int] {
        if count >= 64 { return Array(prefix(64)) }
        return self + Array(repeating: 0, count: 64 - count)
    }
}

// MARK: - 16. Танки

final class TanksWorld: ObservableObject {
    @Published var projectileX: Double = -10
    @Published var projectileY: Double = -10
    @Published var inFlight = false
    @Published var leftAngle: Double = 45
    @Published var rightAngle: Double = 45
    @Published var leftPower: Double = 65
    @Published var rightPower: Double = 65
    @Published var hpLeft: Double = 100
    @Published var hpRight: Double = 100
    @Published var wind: Double = 0.08
    @Published var turn = 0
    @Published var message = "Ход левого танка"

    private(set) var vx: Double = 0
    private(set) var vy: Double = 0
    private var shooter = 0

    let leftX = 0.12
    let rightX = 1.88
    let gravity = 1.15

    func terrain(_ x: Double) -> Double {
        let clamped = max(0, min(2, x))
        return 0.74 + 0.075 * sin(clamped * 5.2) + 0.035 * sin(clamped * 12.7 + 1.1)
    }

    func fire(angle: Double, power: Double, by shooterIndex: Int) {
        guard !inFlight, shooterIndex == turn, hpLeft > 0, hpRight > 0 else { return }
        shooter = shooterIndex
        let speed = 0.55 + power / 100 * 1.05
        let radians = angle * .pi / 180
        let direction = shooterIndex == 0 ? 1.0 : -1.0
        let originX = shooterIndex == 0 ? leftX : rightX
        projectileX = originX + direction * 0.045
        projectileY = terrain(originX) - 0.035
        vx = cos(radians) * speed * direction
        vy = -sin(radians) * speed
        inFlight = true
    }

    func step(dt: Double) {
        guard inFlight else { return }
        vy += gravity * dt
        vx += wind * dt
        projectileX += vx * dt
        projectileY += vy * dt

        if projectileX < 0 || projectileX > 2 { inFlight = false; finish(landedAt: projectileX) }
        else if projectileY > terrain(projectileX), vy > 0 {
            inFlight = false
            finish(landedAt: projectileX)
        }
    }

    private func finish(landedAt x: Double) {
        if shooter == 0, abs(x - rightX) < 0.06 {
            hpRight = max(0, hpRight - 34)
            message = "Попадание! Правый танк: \(Int(hpRight)) HP"
        } else if shooter == 1, abs(x - leftX) < 0.06 {
            hpLeft = max(0, hpLeft - 34)
            message = "Попадание! Левый танк: \(Int(hpLeft)) HP"
        } else {
            message = shooter == 0 ? "Мимо. Ход правого" : "Мимо. Ход левого"
        }
        turn = shooter == 0 ? 1 : 0
        wind = Double.random(in: -0.16...0.16)
        if hpLeft <= 0 { message = "Победа правого танка!" }
        if hpRight <= 0 { message = "Победа левого танка!" }
    }

    func reset() {
        hpLeft = 100; hpRight = 100; inFlight = false; turn = 0
        wind = Double.random(in: -0.16...0.16)
        message = "Новый бой"
    }
}

struct TanksDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var world = TanksWorld()
    @State private var angle: Double = 45
    @State private var power: Double = 65
    @State private var packetID: UUID?
    @State private var timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private var myIndex: Int { link.role == .left ? 0 : 1 }

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Text("HP \(Int(world.hpLeft))").font(.system(size: 10, weight: .bold)).foregroundColor(DuoTheme.cyan)
                Spacer()
                Text(world.message).font(.system(size: 9)).foregroundColor(.white.opacity(0.6)).lineLimit(1)
                Spacer()
                Text("HP \(Int(world.hpRight))").font(.system(size: 10, weight: .bold)).foregroundColor(DuoTheme.magenta)
            }
            .padding(.horizontal, 10).padding(.top, 4)

            GeometryReader { geo in
                Canvas { ctx, size in
                    let role = link.role ?? .left
                    // земля
                    var ground = Path()
                    ground.move(to: CGPoint(x: 0, y: size.height))
                    var x: Double = 0
                    while x <= 2.0 {
                        let local = duoLocalX(x, role)
                        ground.addLine(to: CGPoint(x: CGFloat(local) * size.width,
                                                   y: CGFloat(world.terrain(x)) * size.height))
                        x += 0.02
                    }
                    ground.addLine(to: CGPoint(x: size.width, y: size.height))
                    ground.closeSubpath()
                    ctx.fill(ground, with: .color(Color(red: 0.16, green: 0.13, blue: 0.1)))
                    ctx.stroke(ground, with: .color(DuoTheme.amber.opacity(0.5)), lineWidth: 1)

                    tank(&ctx, x: world.leftX, y: world.terrain(world.leftX), size: size,
                         role: role, color: DuoTheme.cyan, angle: world.leftAngle, flipped: false)
                    tank(&ctx, x: world.rightX, y: world.terrain(world.rightX), size: size,
                         role: role, color: DuoTheme.magenta, angle: world.rightAngle, flipped: true)

                    if world.inFlight {
                        let px = CGFloat(duoLocalX(world.projectileX, role)) * size.width
                        let py = CGFloat(world.projectileY) * size.height
                        ctx.fill(Path(ellipseIn: CGRect(x: px - 4, y: py - 4, width: 8, height: 8)),
                                 with: .color(DuoTheme.amber))
                    }

                    let windWidth = CGFloat(abs(world.wind)) * 160
                    let windRect = CGRect(x: size.width / 2 - windWidth / 2, y: 6,
                                          width: max(2, windWidth), height: 3)
                    ctx.fill(Path(roundedRect: windRect, cornerRadius: 1.5),
                             with: .color(.white.opacity(0.35)))
                }
                .background(LinearGradient(colors: [Color(red: 0.06, green: 0.07, blue: 0.14),
                                                    Color(red: 0.02, green: 0.02, blue: 0.05)],
                                           startPoint: .top, endPoint: .bottom))
            }

            controls
        }
        .onAppear {
            angle = myIndex == 0 ? world.leftAngle : world.rightAngle
            power = myIndex == 0 ? world.leftPower : world.rightPower
            packetID = link.listen { packet in
                guard packet.t == "tanks" else { return }
                switch packet.s {
                case "fire":
                    guard packet.d.count >= 2 else { return }
                    world.fire(angle: packet.d[0], power: packet.d[1], by: 1 - myIndex)
                case "state":
                    guard packet.d.count >= 12 else { return }
                    world.projectileX = packet.d[0]; world.projectileY = packet.d[1]
                    world.inFlight = packet.d[2] > 0.5
                    world.turn = Int(packet.d[3])
                    world.hpLeft = packet.d[4]; world.hpRight = packet.d[5]
                    world.wind = packet.d[6]
                    world.leftAngle = packet.d[7]; world.rightAngle = packet.d[8]
                    world.leftPower = packet.d[9]; world.rightPower = packet.d[10]
                    world.message = world.turn == 0 ? "Ход левого танка" : "Ход правого танка"
                case "reset":
                    world.reset()
                default: break
                }
            }
        }
        .onDisappear {
            if let id = packetID { link.stopListening(id) }
        }
        .onReceive(timer) { _ in
            guard link.role == .left else { return }
            world.step(dt: 1.0 / 60.0)
            if myIndex == 0 { world.leftAngle = angle; world.leftPower = power }
            link.send(DuoPacket(t: "tanks", s: "state",
                                d: [world.projectileX, world.projectileY, world.inFlight ? 1 : 0,
                                    Double(world.turn), world.hpLeft, world.hpRight, world.wind,
                                    world.leftAngle, world.rightAngle, world.leftPower, world.rightPower,
                                    Double(world.hpLeft + world.hpRight)]))
        }
    }

    private var controls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text("Угол \(Int(angle))°").font(.system(size: 9)).frame(width: 62, alignment: .leading)
                Slider(value: $angle, in: 10...80, step: 1)
                Text("Сила \(Int(power))").font(.system(size: 9)).frame(width: 62, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Slider(value: $power, in: 20...100, step: 1)
                Button {
                    if link.role == .left {
                        world.fire(angle: angle, power: power, by: 0)
                    } else {
                        link.send(DuoPacket(t: "tanks", s: "fire", d: [angle, power]), reliable: true)
                    }
                } label: {
                    Text("ВЫСТРЕЛ").font(.system(size: 11, weight: .heavy))
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Capsule().fill(DuoTheme.amber.opacity(0.85)))
                        .foregroundColor(.black)
                }
                .buttonStyle(.plain)
                .disabled(world.turn != myIndex || world.hpLeft <= 0 || world.hpRight <= 0)
            }
        }
        .padding(.horizontal, 10).padding(.bottom, 6)
        .foregroundColor(.white.opacity(0.7))
    }

    private func tank(_ ctx: inout GraphicsContext, x: Double, y: Double, size: CGSize,
                      role: DuoRole, color: Color, angle: Double, flipped: Bool) {
        let px = CGFloat(duoLocalX(x, role)) * size.width
        let py = CGFloat(y) * size.height
        var body = Path()
        body.addRoundedRect(in: CGRect(x: px - 15, y: py - 9, width: 30, height: 9), cornerSize: CGSize(width: 3, height: 3))
        ctx.fill(body, with: .color(color.opacity(0.9)))
        var turret = Path()
        turret.addEllipse(in: CGRect(x: px - 7, y: py - 16, width: 14, height: 10))
        ctx.fill(turret, with: .color(color))
        let radians = angle * .pi / 180
        let dir: CGFloat = flipped ? -1 : 1
        let tipX = px + CGFloat(cos(radians)) * 20 * dir
        let tipY = py - 12 - CGFloat(sin(radians)) * 20
        var barrel = Path()
        barrel.move(to: CGPoint(x: px, y: py - 12))
        barrel.addLine(to: CGPoint(x: tipX, y: tipY))
        ctx.stroke(barrel, with: .color(color), lineWidth: 4)
    }
}

// MARK: - 17. Гонка

final class HighwayWorld: ObservableObject {
    struct Car {
        var lane: Int
        var y: Double
        var speed: Double
    }

    @Published var carLane = 2
    @Published var traffic: [Car] = []
    @Published var score = 0
    @Published var crashed = false
    @Published var best = 0

    private var spawnTimer: Double = 0

    func reset() {
        carLane = 2
        traffic = []
        score = 0
        crashed = false
        spawnTimer = 0
    }

    func shift(_ delta: Int) {
        guard !crashed else { return }
        carLane = max(0, min(3, carLane + delta))
    }

    func step(dt: Double) {
        guard !crashed else { return }
        score += Int(dt * 20)
        if score > best { best = score }
        spawnTimer -= dt
        if spawnTimer <= 0 {
            spawnTimer = Double.random(in: 0.55...1.1)
            let lane = Int.random(in: 0..<4)
            traffic.append(Car(lane: lane, y: -0.15, speed: Double.random(in: 0.45...0.85)))
        }
        for i in traffic.indices {
            traffic[i].y += traffic[i].speed * dt
        }
        traffic.removeAll { $0.y > 1.25 }
        for car in traffic where car.lane == carLane && abs(car.y - 0.82) < 0.09 {
            crashed = true
        }
    }
}

struct HighwayDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var world = HighwayWorld()
    @State private var packetID: UUID?
    @State private var timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    @State private var remoteLane = 2

    private var myLane: Int { link.role == .left ? world.carLane : remoteLane }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Canvas { ctx, size in
                    let role = link.role ?? .left
                    let laneWidth = size.width / 2
                    for lane in 0..<2 {
                        let localLane = role == .left ? lane : lane + 2
                        let x = CGFloat(lane) * laneWidth
                        let rect = CGRect(x: x, y: 0, width: laneWidth, height: size.height)
                        ctx.fill(Path(rect), with: .color(lane % 2 == 0
                                                          ? Color(red: 0.04, green: 0.05, blue: 0.09)
                                                          : Color(red: 0.05, green: 0.06, blue: 0.1)))
                        _ = localLane
                    }
                    // разметка
                    for lane in 0...2 {
                        let x = CGFloat(lane) * laneWidth
                        var y: CGFloat = 0
                        while y < size.height {
                            ctx.fill(Path(CGRect(x: x - 1, y: y, width: 2, height: 22)),
                                     with: .color(.white.opacity(0.22)))
                            y += 44
                        }
                    }
                    if role == .left {
                        ctx.fill(Path(CGRect(x: size.width - 2, y: 0, width: 2, height: size.height)),
                                 with: .color(DuoTheme.cyan.opacity(0.5)))
                    }
                    for car in world.traffic {
                        let laneIndex = role == .left ? car.lane : car.lane - 2
                        guard laneIndex >= 0, laneIndex < 2 else { continue }
                        let x = CGFloat(laneIndex) * laneWidth + laneWidth / 2
                        let y = CGFloat(car.y) * size.height
                        let rect = CGRect(x: x - laneWidth * 0.3, y: y - 26,
                                          width: laneWidth * 0.6, height: 52)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 8),
                                 with: .color(Color(red: 0.95, green: 0.4, blue: 0.3).opacity(0.85)))
                    }
                    let carLaneIndex = role == .left ? world.carLane : world.carLane - 2
                    if carLaneIndex >= 0, carLaneIndex < 2 {
                        let x = CGFloat(carLaneIndex) * laneWidth + laneWidth / 2
                        let y = CGFloat(0.82) * size.height
                        let rect = CGRect(x: x - laneWidth * 0.3, y: y - 28,
                                          width: laneWidth * 0.6, height: 56)
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 10),
                                 with: .color(DuoTheme.cyan.opacity(0.9)))
                        var glow = Path()
                        glow.addEllipse(in: rect.insetBy(dx: 4, dy: 6))
                        ctx.stroke(glow, with: .color(.white.opacity(0.5)), lineWidth: 1)
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0).onEnded { value in
                        let half = geo.size.width / 2
                        move(value.location.x < half ? -1 : 1)
                    }
                )
            }
            VStack {
                HStack {
                    Text("\(world.score) м").font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundColor(DuoTheme.amber)
                    Spacer()
                    Text("DUO HIGHWAY").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Text("рекорд \(world.best)").font(.system(size: 9)).foregroundColor(.white.opacity(0.35))
                }
                .padding(.horizontal, 12).padding(.top, 6)
                Spacer()
                if world.crashed {
                    Button {
                        world.reset()
                        link.send(DuoPacket(t: "highway", s: "reset"), reliable: true)
                    } label: {
                        Text("АВАРИЯ · заново")
                            .font(.system(size: 13, weight: .heavy))
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(Capsule().fill(DuoTheme.amber))
                            .foregroundColor(.black)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                }
            }
        }
        .onAppear {
            packetID = link.listen { packet in
                guard packet.t == "highway" else { return }
                if packet.s == "input" { remoteLane = Int(packet.d.first ?? 2) }
                if packet.s == "state" {
                    world.carLane = Int(packet.d.first ?? 2)
                    world.score = packet.d.count > 1 ? Int(packet.d[1]) : 0
                    world.crashed = packet.d.count > 2 && packet.d[2] > 0.5
                }
                if packet.s == "reset" { world.reset() }
            }
        }
        .onDisappear {
            if let id = packetID { link.stopListening(id) }
        }
        .onReceive(timer) { _ in
            if link.role == .left {
                world.step(dt: 1.0 / 60.0)
                link.send(DuoPacket(t: "highway", s: "state",
                                    d: [Double(world.carLane), Double(world.score), world.crashed ? 1 : 0]))
            }
        }
    }

    private func move(_ delta: Int) {
        world.shift(delta)
        link.send(DuoPacket(t: "highway", s: "input", d: [Double(world.carLane)]))
    }
}

// MARK: - 18. Пинбол

final class PinballWorld: ObservableObject {
    struct Bumper {
        var x: Double
        var y: Double
        var r: Double
        var hit: Double = 0
    }

    @Published var ballX = 1.0
    @Published var ballY = 0.2
    @Published var score = 0
    @Published var balls = 3
    @Published var flipLeft = false
    @Published var flipRight = false
    @Published var bumpers: [Bumper] = []

    private var vx: Double = 0.35
    private var vy: Double = 0.2
    let r: Double = 0.018
    private var cooldown: Double = 1.0

    init() {
        bumpers = [
            Bumper(x: 0.75, y: 0.28, r: 0.035), Bumper(x: 1.25, y: 0.28, r: 0.035),
            Bumper(x: 1.0, y: 0.16, r: 0.03), Bumper(x: 0.55, y: 0.45, r: 0.03),
            Bumper(x: 1.45, y: 0.45, r: 0.03)
        ]
    }

    func resetBall() {
        ballX = 1.0
        ballY = 0.12
        vx = Double.random(in: -0.4...0.4)
        vy = 0.35
        cooldown = 0.6
    }

    func step(dt: Double, leftFlipper: Bool, rightFlipper: Bool) {
        flipLeft = leftFlipper
        flipRight = rightFlipper
        cooldown = max(0, cooldown - dt)

        vy += 0.85 * dt
        ballX += vx * dt
        ballY += vy * dt

        if ballX < r { ballX = r; vx = -vx * 0.85 }
        if ballX > 2 - r { ballX = 2 - r; vx = -vx * 0.85 }
        if ballY < r { ballY = r; vy = -vy * 0.7 }

        for i in bumpers.indices {
            let dx = ballX - bumpers[i].x
            let dy = ballY - bumpers[i].y
            let dist = (dx * dx + dy * dy).squareRoot()
            if dist < bumpers[i].r + r, dist > 0.0001 {
                let nx = dx / dist
                let ny = dy / dist
                ballX = bumpers[i].x + nx * (bumpers[i].r + r + 0.001)
                ballY = bumpers[i].y + ny * (bumpers[i].r + r + 0.001)
                let speed = max(0.55, (vx * vx + vy * vy).squareRoot() * 1.06)
                vx = nx * speed
                vy = ny * speed
                bumpers[i].hit = 1
                score += 25
            }
            bumpers[i].hit = max(0, bumpers[i].hit - dt * 2)
        }

        // флипперы
        let flipperY = 0.85
        if ballY > flipperY - 0.04, ballY < flipperY + 0.06 {
            if ballX < 0.55, leftFlipper, cooldown <= 0 {
                vy = -0.95 - Double.random(in: 0...0.15)
                vx = 0.45 * (ballX < 0.75 ? 1 : -1)
                score += 10
                cooldown = 0.18
            }
            if ballX > 1.45, rightFlipper, cooldown <= 0 {
                vy = -0.95 - Double.random(in: 0...0.15)
                vx = 0.45 * (ballX < 1.25 ? 1 : -1)
                score += 10
                cooldown = 0.18
            }
        }

        if ballY > 1.05 {
            balls = max(0, balls - 1)
            score = max(0, score - 50)
            resetBall()
        }
    }

    func reset() {
        score = 0
        balls = 3
        resetBall()
    }
}

struct PinballDuoView: View {
    @EnvironmentObject var link: DuoLink
    @StateObject private var world = PinballWorld()
    @State private var leftDown = false
    @State private var rightDown = false
    @State private var packetID: UUID?
    @State private var timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()
    @State private var remoteLeft = false
    @State private var remoteRight = false

    private var myLeft: Bool { link.role == .left ? leftDown : remoteLeft }
    private var myRight: Bool { link.role == .left ? remoteRight : rightDown }

    var body: some View {
        ZStack {
            GeometryReader { geo in
                Canvas { ctx, size in
                    let role = link.role ?? .left
                    // корпус стола
                    ctx.fill(Path(CGRect(origin: .zero, size: size)),
                             with: .color(Color(red: 0.03, green: 0.02, blue: 0.07)))

                    for bumper in world.bumpers {
                        let lx = CGFloat(duoLocalX(bumper.x, role)) * size.width
                        guard lx > -40, lx < size.width + 40 else { continue }
                        let rr = CGFloat(bumper.r) * size.width
                        let rect = CGRect(x: lx - rr, y: CGFloat(bumper.y) * size.height - rr,
                                          width: rr * 2, height: rr * 2)
                        ctx.fill(Path(ellipseIn: rect),
                                 with: .color(DuoTheme.magenta.opacity(0.55 + bumper.hit * 0.45)))
                        ctx.stroke(Path(ellipseIn: rect.insetBy(dx: -3, dy: -3)),
                                   with: .color(DuoTheme.magenta.opacity(0.35 + bumper.hit * 0.5)),
                                   lineWidth: 2)
                    }

                    // флипперы
                    let fy = CGFloat(0.85) * size.height
                    let leftAnchor = CGFloat(duoLocalX(0.35, role)) * size.width
                    let rightAnchor = CGFloat(duoLocalX(1.65, role)) * size.width
                    flipper(&ctx, anchor: CGPoint(x: leftAnchor, y: fy), length: size.width * 0.2,
                            angle: myLeft ? -28 : 18, color: DuoTheme.cyan)
                    flipper(&ctx, anchor: CGPoint(x: rightAnchor, y: fy), length: size.width * 0.2,
                            angle: myRight ? 208 : 162, color: DuoTheme.magenta)

                    let bx = CGFloat(duoLocalX(world.ballX, role)) * size.width
                    let br = CGFloat(world.r) * size.width
                    let ball = CGRect(x: bx - br, y: CGFloat(world.ballY) * size.height - br,
                                      width: br * 2, height: br * 2)
                    ctx.fill(Path(ellipseIn: ball), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: ball.insetBy(dx: -2, dy: -2)),
                               with: .color(DuoTheme.magenta.opacity(0.6)), lineWidth: 1)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in press() }
                        .onEnded { _ in release() }
                )
            }
            VStack {
                HStack {
                    Text("\(world.score)").font(.system(size: 20, weight: .heavy, design: .rounded))
                        .foregroundColor(DuoTheme.magenta)
                    Spacer()
                    Text("DUO PINBALL").font(.system(size: 9, weight: .bold)).foregroundColor(.white.opacity(0.4))
                    Spacer()
                    Text("шары: \(world.balls)").font(.system(size: 10)).foregroundColor(.white.opacity(0.5))
                }
                .padding(.horizontal, 12).padding(.top, 6)
                Spacer()
                HStack {
                    Text("ФЛИППЕР").font(.system(size: 8)).foregroundColor(.white.opacity(0.3))
                    Spacer()
                    Button("Новая игра") {
                        world.reset()
                        link.send(DuoPacket(t: "pinball", s: "reset"), reliable: true)
                    }
                    .buttonStyle(ChipStyle(tint: DuoTheme.cyan))
                }
                .padding(.horizontal, 10).padding(.bottom, 4)
            }
        }
        .onAppear {
            packetID = link.listen { packet in
                guard packet.t == "pinball" else { return }
                if packet.s == "flip" {
                    remoteLeft = packet.i == 0 ? packet.f : remoteLeft
                    remoteRight = packet.i == 1 ? packet.f : remoteRight
                }
                if packet.s == "state", link.role != .left, packet.d.count >= 7 {
                    world.ballX = packet.d[0]; world.ballY = packet.d[1]
                    world.score = Int(packet.d[2]); world.balls = Int(packet.d[3])
                    remoteLeft = packet.d[4] > 0.5
                }
                if packet.s == "reset" { world.reset() }
            }
        }
        .onDisappear {
            if let id = packetID { link.stopListening(id) }
        }
        .onReceive(timer) { _ in
            if link.role == .left {
                world.step(dt: 1.0 / 60.0, leftFlipper: leftDown, rightFlipper: remoteRight)
                link.send(DuoPacket(t: "pinball", s: "state",
                                    d: [world.ballX, world.ballY, Double(world.score), Double(world.balls),
                                        leftDown ? 1 : 0, remoteRight ? 1 : 0, 0]))
            }
        }
    }

    private func press() {
        if link.role == .left {
            leftDown = true
            link.send(DuoPacket(t: "pinball", s: "flip", i: 0, f: true))
        } else {
            rightDown = true
            link.send(DuoPacket(t: "pinball", s: "flip", i: 1, f: true))
        }
    }

    private func release() {
        if link.role == .left {
            leftDown = false
            link.send(DuoPacket(t: "pinball", s: "flip", i: 0, f: false))
        } else {
            rightDown = false
            link.send(DuoPacket(t: "pinball", s: "flip", i: 1, f: false))
        }
    }

    private func flipper(_ ctx: inout GraphicsContext, anchor: CGPoint, length: CGFloat,
                         angle: Double, color: Color) {
        let radians = angle * .pi / 180
        let tip = CGPoint(x: anchor.x + CGFloat(cos(radians)) * length,
                          y: anchor.y + CGFloat(sin(radians)) * length)
        var path = Path()
        path.move(to: anchor)
        path.addLine(to: tip)
        ctx.stroke(path, with: .color(color), lineWidth: 7)
        ctx.stroke(path, with: .color(.white.opacity(0.4)), lineWidth: 2)
    }
}

// MARK: - 19. Общий холст

struct DrawSegment: Identifiable {
    let id = UUID()
    var x1: Double
    var y1: Double
    var x2: Double
    var y2: Double
    var colorIndex: Int
}

struct DrawDuoView: View {
    @EnvironmentObject var link: DuoLink
    @State private var segments: [DrawSegment] = []
    @State private var currentStart: CGPoint?
    @State private var colorIndex = 0
    @State private var packetID: UUID?

    private let palette: [Color] = [DuoTheme.cyan, DuoTheme.magenta, DuoTheme.lime,
                                    DuoTheme.amber, .white, DuoTheme.violet]

    var body: some View {
        VStack(spacing: 0) {
            paletteBar
            GeometryReader { geo in
                ZStack {
                    Color(red: 0.03, green: 0.03, blue: 0.06)
                    Canvas { ctx, size in
                        let role = link.role ?? .left
                        for segment in segments {
                            var path = Path()
                            let x1 = CGFloat(duoLocalX(segment.x1, role)) * size.width
                            let x2 = CGFloat(duoLocalX(segment.x2, role)) * size.width
                            if max(x1, x2) < -20 || min(x1, x2) > size.width + 20 { continue }
                            path.move(to: CGPoint(x: x1, y: CGFloat(segment.y1) * size.height))
                            path.addLine(to: CGPoint(x: x2, y: CGFloat(segment.y2) * size.height))
                            ctx.stroke(path, with: .color(palette[min(segment.colorIndex, palette.count - 1)]),
                                       style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        }
                        if role == .left {
                            ctx.fill(Path(CGRect(x: size.width - 2, y: 0, width: 2, height: size.height)),
                                     with: .color(DuoTheme.violet.opacity(0.35)))
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let worldX = worldX(value.location.x, width: geo.size.width)
                            let worldY = Double(value.location.y / max(1, geo.size.height))
                            if let start = currentStart {
                                let segment = DrawSegment(x1: Double(start.x), y1: Double(start.y),
                                                          x2: worldX, y2: worldY, colorIndex: colorIndex)
                                segments.append(segment)
                                link.send(DuoPacket(t: "draw", s: "seg",
                                                    d: [segment.x1, segment.y1, segment.x2, segment.y2,
                                                        Double(segment.colorIndex)]))
                                currentStart = CGPoint(x: worldX, y: worldY)
                            } else {
                                currentStart = CGPoint(x: worldX, y: worldY)
                            }
                        }
                        .onEnded { _ in currentStart = nil }
                )
            }
        }
        .onAppear {
            packetID = link.listen { packet in
                guard packet.t == "draw" else { return }
                if packet.s == "seg", packet.d.count >= 5 {
                    segments.append(DrawSegment(x1: packet.d[0], y1: packet.d[1],
                                                x2: packet.d[2], y2: packet.d[3],
                                                colorIndex: Int(packet.d[4])))
                    if segments.count > 4000 { segments.removeFirst(500) }
                }
                if packet.s == "clear" { segments.removeAll() }
            }
        }
        .onDisappear {
            if let id = packetID { link.stopListening(id) }
        }
    }

    private var paletteBar: some View {
        HStack(spacing: 10) {
            ForEach(0..<palette.count, id: \.self) { index in
                Button {
                    colorIndex = index
                } label: {
                    Circle()
                        .fill(palette[index])
                        .frame(width: 24, height: 24)
                        .overlay(
                            Circle().stroke(Color.white.opacity(colorIndex == index ? 0.9 : 0.15),
                                            lineWidth: colorIndex == index ? 2 : 1)
                        )
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                segments.removeAll()
                link.send(DuoPacket(t: "draw", s: "clear"), reliable: true)
            } label: {
                Image(systemName: "trash").font(.system(size: 12))
            }
            .buttonStyle(.plain).foregroundColor(.white.opacity(0.5))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.black.opacity(0.5))
    }

    private func worldX(_ localX: CGFloat, width: CGFloat) -> Double {
        let local = Double(localX / max(1, width))
        return link.role == .left ? local : local + 1
    }
}
