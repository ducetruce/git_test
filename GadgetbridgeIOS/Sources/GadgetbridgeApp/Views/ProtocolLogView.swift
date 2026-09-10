import SwiftUI
import GadgetbridgeCore
#if canImport(UIKit)
import UIKit
#endif

/// The raw protocol transcript. A first-class screen rather than a debug
/// menu, because the vendor handshake constants are unverified and this is
/// how a real device's answer gets captured — see the README.
struct ProtocolLogView: View {
    @State private var lines: [String] = ProtocolLogger.shared.transcriptLines

    var body: some View {
        VStack(spacing: 0) {
            if lines.isEmpty {
                VStack(spacing: 6) {
                    Text("Nothing logged yet")
                        .font(Instrument.mono(12))
                        .foregroundStyle(Instrument.dim)
                    Text("Connect a device, then come back.")
                        .font(.system(size: 12))
                        .foregroundStyle(Instrument.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            LogLine(text: line)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                }
                .instrumentWell(cornerRadius: 10)
                .padding(.horizontal, 18)
                .padding(.top, 4)
            }

            HStack(spacing: 8) {
                Button("Copy") { copyTranscript() }
                    .buttonStyle(InstrumentButtonStyle(role: .ghost))
                Button("Clear") {
                    ProtocolLogger.shared.clear()
                    lines = []
                }
                .buttonStyle(InstrumentButtonStyle(role: .ghost))
            }
            .padding(.horizontal, 18)
            .padding(.top, 12)

            Text("Never contains your pairing key or session key.")
                .font(.system(size: 11))
                .foregroundStyle(Instrument.faint)
                .padding(.top, 8)
                .padding(.bottom, 16)
        }
        .background(Instrument.ground)
        .navigationTitle("Protocol log")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(Instrument.ground, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    lines = ProtocolLogger.shared.transcriptLines
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .tint(Instrument.amber)
            }
        }
        .onAppear { lines = ProtocolLogger.shared.transcriptLines }
    }

    private func copyTranscript() {
        #if canImport(UIKit)
        UIPasteboard.general.string = ProtocolLogger.shared.transcript
        #endif
    }
}

/// Colours a transcript line by what it means: direction of travel, hex
/// payloads, and — most importantly — responses this code discarded, which
/// get a severity rail because they're the prime suspect when a handshake
/// fails.
private struct LogLine: View {
    let text: String

    private var isDiscarded: Bool {
        text.contains("IGNORED") || text.contains("...ignored")
    }
    private var isOutbound: Bool { text.contains("-> phase") || text.contains("writing") }
    private var isInbound: Bool { text.contains("<- auth notify") }
    private var isFailure: Bool { text.contains("!!") }
    private var isHexPayload: Bool { text.contains(" bytes): ") || text.contains("bytes: ") }

    private var glyph: String {
        if isOutbound { return "→" }
        if isInbound { return "←" }
        if isFailure || isDiscarded { return "!" }
        return "·"
    }

    private var tint: Color {
        if isDiscarded || isFailure { return Instrument.discarded }
        if isInbound { return Instrument.inbound }
        if isOutbound { return Instrument.amber }
        if isHexPayload { return Instrument.dim }
        return Instrument.faint
    }

    var body: some View {
        HStack(alignment: .top, spacing: 5) {
            Text(glyph)
                .font(Instrument.mono(9))
                .foregroundStyle(isDiscarded || isFailure ? Instrument.discarded : tint.opacity(0.8))
                .frame(width: 9, alignment: .center)

            Text(text)
                .font(Instrument.mono(9))
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, isDiscarded ? 5 : 0)
        .overlay(alignment: .leading) {
            if isDiscarded {
                Rectangle()
                    .fill(Instrument.discarded)
                    .frame(width: 2)
            }
        }
        .background(isDiscarded ? Instrument.discarded.opacity(0.05) : .clear)
    }
}
