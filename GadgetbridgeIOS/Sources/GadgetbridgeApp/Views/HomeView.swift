import Charts
import SwiftUI
import GadgetbridgeCore

/// The app's root screen. Deliberately has no app-name title and no device
/// picker: with one tracker the device isn't a choice, it's context — so it
/// collapses to a status line and the reading becomes the top of the screen.
struct HomeView: View {
    @ObservedObject var deviceList: DeviceListViewModel
    let repository: ActivityRepository
    @StateObject private var viewModel: HomeViewModel

    init(deviceList: DeviceListViewModel, repository: ActivityRepository, settings: UserSettings) {
        self.deviceList = deviceList
        self.repository = repository
        _viewModel = StateObject(wrappedValue: HomeViewModel(repository: repository, settings: settings))
    }

    /// The device the screen is about: whichever is connected, else the
    /// first paired one.
    private var activeDevice: Device? {
        deviceList.pairedDevices.first { $0.connectionState == .connected }
            ?? deviceList.pairedDevices.first
    }

    var body: some View {
        VStack(spacing: 0) {
            if let device = activeDevice {
                DeviceStatusLine(device: device, deviceList: deviceList, repository: repository)
                Divider().overlay(Instrument.rule)
            }

            if activeDevice == nil {
                EmptyStateView()
            } else {
                content
            }
        }
        .background(Instrument.ground)
        .onAppear { viewModel.refresh(for: activeDevice) }
        .onChange(of: deviceList.pairedDevices) { _ in
            viewModel.refresh(for: activeDevice)
        }
        // Live readings are appended rather than triggering a re-read of
        // the whole window — at 1 Hz that would mean decoding the entire
        // range on every heartbeat.
        .onReceive(deviceList.$lastHeartRateSample.compactMap { $0 }) { sample in
            viewModel.append(sample)
        }
        .onReceive(deviceList.$lastHRVAt.compactMap { $0 }) { _ in
            viewModel.refreshHRV()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .center) {
                Text("Heart rate").instrumentLabel()
                Spacer()
                RangePicker(selection: $viewModel.range)
            }
            .padding(.top, 12)

            HeroReadout(
                value: viewModel.latest,
                minimum: viewModel.minimum,
                maximum: viewModel.maximum,
                zone: viewModel.zone
            )

            HeartRateTrace(samples: viewModel.samples)
                .frame(maxHeight: .infinity)

            StatsStrip(
                resting: viewModel.resting,
                hrv: viewModel.hrv,
                battery: activeDevice?.battery?.level
            )
            .padding(.bottom, 16)
        }
        .padding(.horizontal, 18)
    }
}

// MARK: - Device status line

private struct DeviceStatusLine: View {
    let device: Device
    @ObservedObject var deviceList: DeviceListViewModel
    let repository: ActivityRepository

    private var isLinked: Bool {
        device.connectionState == .connected || device.connectionState == .syncing
    }

    var body: some View {
        NavigationLink {
            DeviceDetailView(device: device, viewModel: deviceList, repository: repository)
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(isLinked ? Instrument.linked : Instrument.faint)
                    .frame(width: 7, height: 7)
                    .shadow(color: isLinked ? Instrument.linked.opacity(0.55) : .clear, radius: 4)

                Text(device.name)
                    .font(Instrument.mono(11, weight: .medium))
                    .foregroundStyle(Instrument.ink)
                    .lineLimit(1)

                Text("·").font(Instrument.mono(11)).foregroundStyle(Instrument.rule)

                Text(isLinked ? "Linked" : "Idle")
                    .font(Instrument.mono(11))
                    .foregroundStyle(isLinked ? Instrument.linked : Instrument.faint)

                Spacer(minLength: 8)

                if let battery = device.battery {
                    Text("\(battery.level)%")
                        .font(Instrument.mono(11))
                        .monospacedDigit()
                        .foregroundStyle(Instrument.amber)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Instrument.faint)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hero readout

private struct HeroReadout: View {
    let value: Int?
    let minimum: Int?
    let maximum: Int?
    let zone: HeartRateZone?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(value.map(String.init) ?? "––")
                .font(Instrument.mono(66, weight: .medium))
                .monospacedDigit()
                .kerning(-3)
                .foregroundStyle(Instrument.pulse)
                .shadow(color: Instrument.pulse.opacity(0.34), radius: 18)

            Text("bpm")
                .font(Instrument.mono(11.5))
                .foregroundStyle(Instrument.dim)

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                // Only shown once a maximum heart rate is configured —
                // otherwise there's nothing to compute a zone against.
                if let zone {
                    Text("Z\(zone.rawValue) \(zone.name)")
                        .font(Instrument.mono(10))
                        .foregroundStyle(Instrument.amber)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Instrument.amberSoft))
                }
                if let minimum, let maximum {
                    Text("min \(minimum) · max \(maximum)")
                        .font(Instrument.mono(10))
                        .monospacedDigit()
                        .foregroundStyle(Instrument.faint)
                }
            }
        }
    }
}

// MARK: - Range picker

private struct RangePicker: View {
    @Binding var selection: TimeRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TimeRange.allCases) { range in
                Button {
                    selection = range
                } label: {
                    Text(range.rawValue)
                        .font(Instrument.mono(9.5))
                        .tracking(0.6)
                        .foregroundStyle(selection == range ? Instrument.amber : Instrument.faint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            if selection == range {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Instrument.amberSoft)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .instrumentWell(cornerRadius: 7)
    }
}

// MARK: - Trace

private struct HeartRateTrace: View {
    let samples: [HeartRateSample]

    /// Pad the domain so the trace never touches the well's edges, and keep
    /// the gridlines on round values the scale actually reaches.
    private var domain: ClosedRange<Int> {
        let values = samples.map(\.beatsPerMinute)
        guard let low = values.min(), let high = values.max() else { return 50...90 }
        return (low - 8)...(high + 8)
    }

    private var gridValues: [Int] {
        stride(from: (domain.lowerBound / 10 + 1) * 10, through: domain.upperBound, by: 10).map { $0 }
    }

    var body: some View {
        Group {
            if samples.count < 2 {
                VStack(spacing: 6) {
                    Text("Waiting for readings")
                        .font(Instrument.mono(11))
                        .foregroundStyle(Instrument.faint)
                    Text("Connect the strap and wear it for a moment")
                        .font(.system(size: 11))
                        .foregroundStyle(Instrument.faint.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity)
        .instrumentWell()
    }

    private var chart: some View {
        Chart {
            ForEach(samples, id: \.self) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    yStart: .value("Base", domain.lowerBound),
                    yEnd: .value("Heart rate", sample.beatsPerMinute)
                )
                .foregroundStyle(
                    .linearGradient(
                        colors: [Instrument.pulse.opacity(0.30), Instrument.pulse.opacity(0)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Heart rate", sample.beatsPerMinute)
                )
                .foregroundStyle(Instrument.pulse)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
            }

            // Min and max called out on the curve itself, rather than a
            // number on every point.
            if let peak = samples.max(by: { $0.beatsPerMinute < $1.beatsPerMinute }) {
                PointMark(x: .value("Time", peak.timestamp), y: .value("Heart rate", peak.beatsPerMinute))
                    .symbolSize(18)
                    .foregroundStyle(Instrument.pulse.opacity(0.85))
                    .annotation(position: .top, spacing: 3) {
                        Text("\(peak.beatsPerMinute)")
                            .font(Instrument.mono(8))
                            .foregroundStyle(Instrument.dim)
                    }
            }
            if let trough = samples.min(by: { $0.beatsPerMinute < $1.beatsPerMinute }) {
                PointMark(x: .value("Time", trough.timestamp), y: .value("Heart rate", trough.beatsPerMinute))
                    .symbolSize(18)
                    .foregroundStyle(Instrument.pulse.opacity(0.85))
                    .annotation(position: .bottom, spacing: 3) {
                        Text("\(trough.beatsPerMinute)")
                            .font(Instrument.mono(8))
                            .foregroundStyle(Instrument.dim)
                    }
            }

            if let live = samples.last {
                PointMark(x: .value("Time", live.timestamp), y: .value("Heart rate", live.beatsPerMinute))
                    .symbolSize(90)
                    .foregroundStyle(Instrument.pulse)
            }
        }
        .chartYScale(domain: domain)
        .chartYAxis {
            AxisMarks(values: gridValues) {
                AxisGridLine().foregroundStyle(Instrument.rule)
                AxisValueLabel()
                    .font(Instrument.mono(8.5))
                    .foregroundStyle(Instrument.faint)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) {
                AxisTick(length: 4).foregroundStyle(Instrument.faint)
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(Instrument.mono(8.5))
                    .foregroundStyle(Instrument.faint)
            }
        }
    }
}

// MARK: - Stats strip

private struct StatsStrip: View {
    let resting: Int?
    let hrv: Double?
    let battery: Int?

    var body: some View {
        HStack(spacing: 1) {
            statCell("Resting", resting.map(String.init) ?? "––", tint: Instrument.ink)
            statCell("HRV", hrv.map { "\(Int($0.rounded()))" } ?? "––", tint: Instrument.ink)
            statCell("Battery", battery.map { "\($0)%" } ?? "––", tint: Instrument.amber)
        }
        .background(Instrument.rule)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Instrument.rule, lineWidth: 1)
        )
    }

    private func statCell(_ key: String, _ value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(key)
                .font(Instrument.mono(9))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Instrument.faint)
            Text(value)
                .font(Instrument.mono(17))
                .monospacedDigit()
                .foregroundStyle(tint)
                .shadow(color: tint == Instrument.amber ? Instrument.amber.opacity(0.3) : .clear, radius: 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 11)
        .background(
            LinearGradient(
                colors: [Instrument.panelHighlight, Instrument.panel],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 10) {
            Spacer()
            Text("No device linked")
                .font(Instrument.mono(13))
                .foregroundStyle(Instrument.dim)
            Text("Pair a tracker from the Devices tab to start reading.")
                .font(.system(size: 13))
                .multilineTextAlignment(.center)
                .foregroundStyle(Instrument.faint)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
