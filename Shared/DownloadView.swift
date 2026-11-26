import SwiftUI
import UIKit
import Core

struct DownloadView: View {
    @State var model: DownloadModel
    var onClose: () -> Void
    var onBusyChange: (Bool) -> Void = { _ in }
    var openInApp: ((URL) -> Bool)? = nil

    @State private var filesURL: URL?
    @State private var showFiles = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    content
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
            .safeAreaInset(edge: .bottom) { actions.padding(.horizontal, 20).padding(.bottom, 12) }
            .navigationTitle("YT to MP4")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { model.cleanUp(); onClose() }
                        .disabled(model.isBusy)
                }
            }
            .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil && model.message != "Saved to Photos" }, set: { if !$0 { model.message = nil } })) {
                Button("OK", role: .cancel) {}
            }
        }
        .fileMover(isPresented: $showFiles, file: filesURL) { _ in }
        .task { if case .loading = model.phase { await model.load() } }
        .onChange(of: model.isBusy) { _, busy in onBusyChange(busy) }
        .sensoryFeedback(.success, trigger: model.phase.isDone)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            AsyncImage(url: URL(string: "https://i.ytimg.com/vi/\(model.videoID)/hqdefault.jpg")) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary).overlay(ProgressView())
            }
            .frame(maxWidth: .infinity)
            .aspectRatio(16 / 9, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 22, style: .continuous))
            .overlay(alignment: .topLeading) {
                if model.isLive {
                    Label("LIVE", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(.red, in: .capsule)
                        .foregroundStyle(.white)
                        .padding(12)
                }
            }
            .accessibilityHidden(true)

            if let info = model.info {
                Text(info.title).font(.title3.weight(.semibold)).lineLimit(3)
                if !info.author.isEmpty {
                    Text(info.author).font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            HStack(spacing: 12) {
                ProgressView()
                Text("Fetching video…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)

        case .ready:
            qualityCard

        case .working(let title, let detail, let progress):
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    if let progress { Text(progress, format: .percent.precision(.fractionLength(0))).monospacedDigit().foregroundStyle(.secondary) }
                }
                if let progress { ProgressView(value: progress).tint(.accentColor) } else { ProgressView().frame(maxWidth: .infinity) }
                Text(detail).font(.footnote).foregroundStyle(.secondary).monospacedDigit()
                Text(model.inExtension ? "Keep this sheet open until it's done." : "Keep the app open until it's done.")
                    .font(.footnote).foregroundStyle(.tertiary)
            }
            .padding(18)
            .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))

        case .done:
            VStack(spacing: 10) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.green)
                    .symbolEffect(.bounce, value: model.phase.isDone)
                Text(model.savedToPhotos ? "Saved to Photos" : "Your MP4 is ready")
                    .font(.title3.weight(.semibold))
                Text("H.264 · AAC · plays on WhatsApp, iMessage and everywhere else")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)

        case .failed(let message, let needsSignIn):
            ContentUnavailableView {
                Label(needsSignIn ? "Sign-in required" : "Couldn't get this video", systemImage: needsSignIn ? "person.crop.circle.badge.exclamationmark" : "exclamationmark.triangle")
            } description: {
                Text(message)
            }
        }
    }

    private var qualityCard: some View {
        VStack(spacing: 0) {
            HStack {
                Label("Quality", systemImage: "sparkles.tv")
                Spacer()
                if model.isLive {
                    Picker("Quality", selection: $model.selectedLive) {
                        ForEach(model.liveVariants) { Text($0.label).tag(Optional($0)) }
                    }
                } else {
                    Picker("Quality", selection: $model.selectedItag) {
                        ForEach(model.options) { o in
                            Text(o.label + (o.needsConversion ? "  ·  converts" : "")).tag(Optional(o.video.itag))
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            .padding(.leading, 18).padding(.trailing, 8).padding(.vertical, 8)

            Divider().padding(.leading, 18)

            HStack {
                Label(model.isLive ? "Records from now until you stop" : "Size", systemImage: model.isLive ? "record.circle" : "internaldrive")
                Spacer()
                if let o = model.selected, !model.isLive {
                    Text("≈ " + DownloadModel.bytes(o.estimatedBytes)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(18)

            if let o = model.selected, o.needsConversion, !model.isLive {
                Divider().padding(.leading, 18)
                Label("YouTube only has \(o.label) as AV1, so it's converted to H.264 on your iPhone so it plays everywhere.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 22, style: .continuous))
    }

    // MARK: Actions

    @ViewBuilder private var actions: some View {
        switch model.phase {
        case .loading:
            EmptyView()
        case .ready:
            if model.mustContinueInApp, let openInApp {
                VStack(spacing: 8) {
                    primary(model.isLive ? "Record in App" : "Convert in App", systemImage: "arrow.up.forward.app") {
                        let url = AppLinks.url(videoID: model.videoID, quality: model.selectionKey)
                        if openInApp(url) { model.cleanUp(); onClose() } else {
                            UIPasteboard.general.string = "https://youtu.be/\(model.videoID)"
                            model.message = "Open the YT to MP4 app — the link is copied, just tap Paste."
                        }
                    }
                    Text(model.isLive ? "Live recording runs in the app so it can keep going." : "4K conversion needs the full app's memory.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                primary(model.isLive ? "Start Recording" : "Download", systemImage: model.isLive ? "record.circle" : "arrow.down.circle.fill") { model.start() }
            }
        case .working(let title, _, _):
            if model.isLive && title == "Recording live" {
                primary("Stop & Save", systemImage: "stop.circle.fill") { model.finishRecordingTapped() }
            } else {
                Button("Cancel", role: .cancel) { model.cancel() }
                    .buttonStyle(.glass).controlSize(.large).frame(maxWidth: .infinity)
            }
        case .done(let url):
            VStack(spacing: 10) {
                primary(model.savedToPhotos ? "Saved to Photos" : "Save to Photos", systemImage: model.savedToPhotos ? "checkmark" : "photo.on.rectangle") {
                    Task { await model.saveToPhotos(url) }
                }
                .disabled(model.savedToPhotos)
                HStack(spacing: 10) {
                    Button { filesURL = model.exportCopy(url); showFiles = filesURL != nil } label: {
                        Label("Save to Files", systemImage: "folder").frame(maxWidth: .infinity)
                    }
                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.glass)
                .controlSize(.large)
            }
        case .failed(_, let needsSignIn):
            if needsSignIn, let openInApp {
                primary("Open App to Sign In", systemImage: "person.crop.circle") {
                    if openInApp(URL(string: "\(AppLinks.scheme)://signin")!) { onClose() }
                }
            } else {
                primary("Try Again", systemImage: "arrow.clockwise") { Task { await model.load() } }
            }
        }
    }

    private func primary(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.large)
    }
}

extension DownloadModel.Phase {
    var isDone: Bool { if case .done = self { return true }; return false }
}
