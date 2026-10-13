import SwiftUI
import AVFoundation
import PDFKit
import UniformTypeIdentifiers
import MediaPlayer
import ZIPFoundation

@main
struct LeafVoiceApp: App {
    var body: some Scene { WindowGroup { ReaderHome() } }
}

struct StoredBook: Codable, Identifiable {
    var id = UUID()
    var title: String
    var text: String
    var position: Int = 0
}

@MainActor
final class ReaderModel: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published var books: [StoredBook] = []
    @Published var currentID: UUID?
    @Published var playing = false
    @Published var rate: Float = 0.49
    @Published var voiceID = ""
    @Published var segmentIndex = 0
    @Published var importing = false
    @Published var errorMessage: String?
    private let speaker = AVSpeechSynthesizer()
    private var segments: [String] = []
    private var playToken = UUID()

    var selectedIndex: Int? { books.firstIndex { $0.id == currentID } }
    var book: StoredBook? {
        guard let i = selectedIndex else { return nil }
        return books[i]
    }
    var voices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().sorted {
            if $0.quality.rawValue != $1.quality.rawValue { return $0.quality.rawValue > $1.quality.rawValue }
            return $0.name < $1.name
        }
    }

    override init() {
        super.init()
        speaker.delegate = self
        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playback, mode: .spokenAudio, options: [.allowAirPlay, .allowBluetooth])
        try? audio.setActive(true)
        if let data = UserDefaults.standard.data(forKey: "books"),
           let saved = try? JSONDecoder().decode([StoredBook].self, from: data) { books = saved }
        if let value = UserDefaults.standard.string(forKey: "selected"), let id = UUID(uuidString: value) { currentID = id }
        rate = UserDefaults.standard.object(forKey: "rate") as? Float ?? 0.49
        voiceID = UserDefaults.standard.string(forKey: "voice") ?? ""
        if let b = book { prepare(b) }
        let controls = MPRemoteCommandCenter.shared()
        controls.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.play() }; return .success }
        controls.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        controls.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(1) }; return .success }
        controls.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-1) }; return .success }
    }

    func persist() {
        if let data = try? JSONEncoder().encode(books) { UserDefaults.standard.set(data, forKey: "books") }
        UserDefaults.standard.set(currentID?.uuidString, forKey: "selected")
        UserDefaults.standard.set(rate, forKey: "rate")
        UserDefaults.standard.set(voiceID, forKey: "voice")
    }
    private func split(_ text: String) -> [String] {
        let pieces = text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
        var result: [String] = []
        for p in pieces {
            let part = p.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if part.count > 400 {
                var words = part.split(separator: " ")
                while !words.isEmpty {
                    var chunk = ""
                    while let w = words.first, chunk.count + w.count < 350 {
                        chunk += (chunk.isEmpty ? "" : " ") + w
                        words.removeFirst()
                    }
                    if !chunk.isEmpty { result.append(chunk) }
                    else if !words.isEmpty { result.append(String(words.removeFirst())) }
                }
            } else { result.append(part) }
        }
        return result
    }
    func prepare(_ b: StoredBook) {
        segments = split(b.text)
        segmentIndex = min(max(0,b.position), max(0,segments.count-1))
    }
    func open(_ b: StoredBook) {
        stop()
        currentID = b.id
        prepare(b)
        persist()
    }
    func importBook(_ url: URL) {
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let ext = url.pathExtension.lowercased()
            var text = ""
            if ext == "epub" {
                text = try EPUBReader.read(url)
            } else if ext == "pdf" {
                guard let doc = PDFDocument(url: url) else { throw NSError(domain:"LeafVoice",code:1,userInfo:[NSLocalizedDescriptionKey:"Cannot open PDF"]) }
                text = (0..<doc.pageCount).compactMap { doc.page(at:$0)?.string }.joined(separator:"\n\n")
            } else {
                let data = try Data(contentsOf: url)
                text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
            }
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {
                throw NSError(domain:"LeafVoice",code:2,userInfo:[NSLocalizedDescriptionKey:"This file contains no extractable text. Scanned PDFs need OCR."])
            }
            let b = StoredBook(title:url.deletingPathExtension().lastPathComponent, text:text)
            books.insert(b, at:0)
            open(b)
        } catch { errorMessage = error.localizedDescription }
    }
    func play() {
        guard !segments.isEmpty else { return }
        if speaker.isPaused { speaker.continueSpeaking(); playing = true; return }
        if speaker.isSpeaking { return }
        sayCurrent()
    }
    private func sayCurrent() {
        guard segmentIndex >= 0 && segmentIndex < segments.count else { stop(); return }
        let utterance = AVSpeechUtterance(string:segments[segmentIndex])
        utterance.rate = rate
        if let voice = AVSpeechSynthesisVoice(identifier:voiceID) { utterance.voice = voice }
        playing = true
        speaker.speak(utterance)
        updateNowPlaying()
    }
    func pause() {
        if speaker.isSpeaking { speaker.pauseSpeaking(at:.immediate) }
        playing = false
        updateNowPlaying()
    }
    func stop() {
        playToken = UUID()
        speaker.stopSpeaking(at:.immediate)
        playing = false
        updateNowPlaying()
    }
    func skip(_ offset: Int) {
        stop()
        segmentIndex = min(max(0, segmentIndex + offset), max(0, segments.count - 1))
        savePosition()
        play()
    }
    func seek(_ index: Int) {
        stop()
        segmentIndex = min(max(0, index), max(0,segments.count - 1))
        savePosition()
    }
    func savePosition() {
        if let i = selectedIndex { books[i].position = segmentIndex }
        persist()
    }
    func changeVoice(_ id: String) {
        let shouldResume = playing
        stop()
        voiceID = id
        persist()
        if shouldResume { play() }
    }
    func changeRate(_ value: Float) {
        let shouldResume = playing
        stop()
        rate = value
        persist()
        if shouldResume { play() }
    }
    private func updateNowPlaying() {
        guard let b = book else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle:b.title,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(segmentIndex)
        ]
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.playing else { return }
            self.segmentIndex += 1
            self.savePosition()
            if self.segmentIndex < self.segments.count { self.sayCurrent() }
            else { self.stop() }
        }
    }
}

struct ReaderHome: View {
    @StateObject private var model = ReaderModel()
    var body: some View {
        NavigationStack {
            Group {
                if let book = model.book {
                    VStack(spacing:14) {
                        Text(book.title).font(.headline).lineLimit(1)
                        ScrollView {
                            Text(book.text).font(.system(size:19,design:.serif))
                                .frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                                .padding(.horizontal)
                        }
                        if !book.text.isEmpty {
                            Text("Narration segment \(model.segmentIndex+1)").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing:36) {
                            Button { model.skip(-1) } label:{ Image(systemName:"backward.end.fill") }
                            Button { model.playing ? model.pause() : model.play() } label:{
                                Image(systemName:model.playing ? "pause.circle.fill":"play.circle.fill")
                                    .font(.system(size:56))
                            }
                            Button { model.skip(1) } label:{ Image(systemName:"forward.end.fill") }
                        }.font(.title2).padding(.bottom,4)
                        VStack {
                            HStack {
                                Text("Speed")
                                Slider(value:Binding(get:{Double(model.rate)},set:{model.changeRate(Float($0))}),in:0.35...0.65)
                                Text(String(format:"%.2f",model.rate)).monospacedDigit()
                            }
                            Picker("Narrator",selection:Binding(get:{model.voiceID},set:{model.changeVoice($0)})) {
                                Text("System default").tag("")
                                ForEach(model.voices,id:\.identifier) { voice in
                                    Text("\(voice.name) (\(voice.language)) • \(quality(voice))").tag(voice.identifier)
                                }
                            }.pickerStyle(.menu)
                        }.padding(.horizontal)
                    }
                } else {
                    ContentUnavailableView("Your audiobook library", systemImage:"books.vertical",description:Text("Import an EPUB, TXT or text-based PDF and listen using the iPhone's built-in voices."))
                }
            }
            .navigationTitle("LeafVoice")
            .toolbar {
                ToolbarItem(placement:.topBarLeading) {
                    Menu {
                        ForEach(model.books) { book in
                            Button(book.title) { model.open(book) }
                        }
                    } label: { Image(systemName:"books.vertical") }
                }
                ToolbarItem(placement:.topBarTrailing) {
                    Button { model.importing = true } label: { Image(systemName:"plus") }
                }
            }
            .fileImporter(isPresented:$model.importing,allowedContentTypes:[.plainText,.pdf,UTType(filenameExtension:"epub") ?? .data]) { result in
                switch result {
                case .success(let url): model.importBook(url)
                case .failure(let error): model.errorMessage = error.localizedDescription
                }
            }
            .alert("Could not import",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0 {model.errorMessage=nil}})) {
                Button("OK",role:.cancel) { model.errorMessage=nil }
            } message: {Text(model.errorMessage ?? "")}
        }
    }
    private func quality(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }
}
