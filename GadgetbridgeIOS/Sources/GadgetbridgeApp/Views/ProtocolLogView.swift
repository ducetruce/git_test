import SwiftUI
import GadgetbridgeCore
#if canImport(UIKit)
import UIKit
#endif

/// Shows the raw protocol transcript (`ProtocolLogger.shared`) so it can be
/// copied off the device. The same lines also go to stdout, so they appear
/// in Xcode's console when running attached — this view is for when you're
/// running untethered, or want to paste the bytes somewhere.
struct ProtocolLogView: View {
    @State private var transcript = ProtocolLogger.shared.transcript

    var body: some View {
        ScrollView {
            Text(transcript.isEmpty ? "Nothing logged yet. Connect a device, then come back." : transcript)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle("Protocol log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    transcript = ProtocolLogger.shared.transcript
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            #if canImport(UIKit)
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    UIPasteboard.general.string = ProtocolLogger.shared.transcript
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
            }
            #endif
            ToolbarItem(placement: .secondaryAction) {
                Button(role: .destructive) {
                    ProtocolLogger.shared.clear()
                    transcript = ""
                } label: {
                    Label("Clear", systemImage: "trash")
                }
            }
        }
        .onAppear { transcript = ProtocolLogger.shared.transcript }
    }
}
