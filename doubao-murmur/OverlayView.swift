import AppKit
import SwiftUI

struct OverlayView: View {
    @ObservedObject var appState: AppState
    let onTextViewReady: (NSTextView) -> Void

    var body: some View {
        HStack(spacing: 12) {
            RecordingDot(state: appState.recordingState)

            IMETextView(
                text: $appState.transcriptionText,
                onTextViewReady: onTextViewReady
            )
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .opacity(0.6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }
}

/// Status indicator: a soft dot that breathes while recording and stays
/// quiet otherwise. Color carries the state, so no text label is needed.
private struct RecordingDot: View {
    let state: RecordingState
    @State private var breathing = false

    private var color: Color {
        switch state {
        case .recording: return .red
        case .starting, .stopping: return .orange
        case .idle: return .gray
        }
    }

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .shadow(color: color.opacity(0.6), radius: 3)
            .scaleEffect(breathing && state == .recording ? 1.35 : 1.0)
            .opacity(state == .recording ? (breathing ? 0.65 : 1.0) : 0.8)
            .animation(
                state == .recording
                    ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                    : .default,
                value: breathing
            )
            .onAppear { breathing = true }
    }
}

private struct IMETextView: NSViewRepresentable {
    @Binding var text: String
    let onTextViewReady: (NSTextView) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.string = text
        textView.font = .systemFont(ofSize: 15)
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.drawsBackground = false
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        DispatchQueue.main.async {
            onTextViewReady(textView)
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != text && !textView.hasMarkedText() {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: IMETextView

        init(parent: IMETextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}
