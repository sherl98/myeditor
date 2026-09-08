import ManuscriptCore
import SwiftUI

private struct RailFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ChapterRail: View {
    let session: DocumentSession
    let application: ApplicationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered: String?
    @State private var presented: String?
    @State private var revealTask: Task<Void, Never>?
    @State private var frames: [String: CGRect] = [:]
    @State private var cardHeight: CGFloat = 82
    private let spacing: CGFloat = 12

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let headings = session.primaryHeadings
            let coordinate = "rail-\(session.id)"
            ZStack(alignment: .topLeading) {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            ForEach(headings) { heading in
                                Button {
                                    application.navigate(session, to: heading.id)
                                } label: {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(
                                            hovered == heading.id
                                                ? Color.primary
                                                : (heading.id == session.activePrimaryID
                                                    ? Color.accentColor
                                                    : Color.secondary.opacity(0.5))
                                        )
                                        .frame(
                                            width: hovered == heading.id ? 44 : 20,
                                            height: heading.id == session.activePrimaryID ? 3 : 2
                                        )
                                        .frame(width: 46, height: spacing, alignment: .leading)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .padding(.leading, 11)
                                .frame(width: 58, height: spacing, alignment: .leading)
                                .id(heading.id)
                                .animation(
                                    reduceMotion ? nil : .easeOut(duration: 0.12),
                                    value: hovered == heading.id
                                )
                                .onHover { inside in
                                    if inside {
                                        setHovered(heading.id)
                                    } else if hovered == heading.id {
                                        setHovered(nil)
                                    }
                                }
                                .background(
                                    GeometryReader { row in
                                        Color.clear.preference(
                                            key: RailFrames.self,
                                            value: [heading.id: row.frame(in: .named(coordinate))])
                                    }
                                )
                                .accessibilityLabel(
                                    "\(heading.title)，约 \(heading.characterCount) 字"
                                )
                                .accessibilityHint("跳转到此章节")
                                .accessibilityAddTraits(
                                    heading.id == session.activePrimaryID ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 6)
                        .frame(minHeight: height, alignment: .center)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: session.activePrimaryID) {
                        guard let id = session.activePrimaryID, let frame = frames[id],
                            frame.minY < 0 || frame.maxY > height
                        else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                if let presented, let heading = headings.first(where: { $0.id == presented }),
                    let frame = frames[presented]
                {
                    let tick = frame.midY
                    if tick >= 0 && tick <= height {
                        let center = min(
                            max(tick, cardHeight / 2), max(cardHeight / 2, height - cardHeight / 2))
                        ChapterPreviewCard(
                            title: heading.title, count: heading.characterCount.formatted(),
                            pointerY: tick - center + cardHeight / 2
                        )
                        .frame(width: 256)
                        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) {
                            cardHeight = $0
                        }
                        .position(x: 56 + 128, y: center)
                        .allowsHitTesting(false).accessibilityHidden(true)
                    }
                }
            }
            .coordinateSpace(name: coordinate)
            .onPreferenceChange(RailFrames.self) { frames = $0 }
            .onChange(of: geometry.size) { clearHover() }
        }
        .onChange(of: application.activeDocumentID) {
            if application.activeDocumentID != session.id { clearHover() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSWindow.willStartLiveResizeNotification)
        ) { _ in clearHover() }
        .onChange(of: session.primaryHeadings.map(\.id)) { clearHover() }
        .onDisappear { clearHover() }
    }

    private func setHovered(_ id: String?) {
        guard hovered != id else { return }
        hovered = id
        revealTask?.cancel()
        if presented != nil, let id {
            presented = id
            return
        }
        revealTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(id == nil ? 60 : 150)) } catch { return }
            guard hovered == id else { return }
            presented = id
            revealTask = nil
        }
    }
    private func clearHover() {
        revealTask?.cancel()
        revealTask = nil
        hovered = nil
        presented = nil
    }
}

private struct ChapterPreviewCard: View {
    let title: String
    let count: String
    let pointerY: CGFloat
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Text("约 \(count) 字").font(.system(size: 13)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 14).padding(.leading, 24).padding(.trailing, 18)
        .background {
            ChapterBubble(pointerY: pointerY)
                .fill(Color(nsColor: .controlBackgroundColor))
                .shadow(color: .black.opacity(0.1), radius: 12, y: 5)
        }
        .overlay(
            ChapterBubble(pointerY: pointerY).stroke(
                Color(nsColor: .separatorColor).opacity(0.65), lineWidth: 1))
    }
}

private struct ChapterBubble: Shape {
    let pointerY: CGFloat
    func path(in rect: CGRect) -> Path {
        let left: CGFloat = 7
        let radius: CGFloat = 10
        let tip = min(max(pointerY, radius + 6), rect.height - radius - 6)
        var path = Path()
        path.move(to: CGPoint(x: left + radius, y: 0))
        path.addLine(to: CGPoint(x: rect.width - radius, y: 0))
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: radius), control: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.width - radius, y: rect.height),
            control: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: left + radius, y: rect.height))
        path.addQuadCurve(
            to: CGPoint(x: left, y: rect.height - radius), control: CGPoint(x: left, y: rect.height)
        )
        path.addLine(to: CGPoint(x: left, y: tip + 6))
        path.addLine(to: CGPoint(x: 0, y: tip))
        path.addLine(to: CGPoint(x: left, y: tip - 6))
        path.addLine(to: CGPoint(x: left, y: radius))
        path.addQuadCurve(to: CGPoint(x: left + radius, y: 0), control: CGPoint(x: left, y: 0))
        path.closeSubpath()
        return path
    }

}
