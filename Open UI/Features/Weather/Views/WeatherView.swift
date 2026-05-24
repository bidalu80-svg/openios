import SwiftUI

struct WeatherView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var snapshot: LocalWeatherSnapshot?
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && snapshot == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let snapshot {
                    weatherContent(snapshot)
                } else {
                    ContentUnavailableView(
                        "暂无天气",
                        systemImage: "cloud.sun",
                        description: Text(errorMessage ?? "点击刷新读取当前位置天气。")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(theme.background.ignoresSafeArea())
            .navigationTitle("天气")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 32, height: 32)
                            .background(theme.surfaceContainer)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(theme.brandPrimary)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                }
            }
            .task {
                if snapshot == nil {
                    await load()
                }
            }
            .alert("错误", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("确定") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func weatherContent(_ snapshot: LocalWeatherSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(snapshot.locationName ?? "当前位置")
                                .font(.headline)
                                .foregroundStyle(theme.textSecondary)
                            Text(snapshot.condition)
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(theme.textPrimary)
                        }
                        Spacer()
                        Image(systemName: snapshot.symbolName)
                            .font(.system(size: 38, weight: .medium))
                            .symbolRenderingMode(.multicolor)
                    }

                    Text("\(Int(snapshot.temperatureCelsius.rounded()))°")
                        .font(.system(size: 76, weight: .semibold, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                        .contentTransition(.numericText())
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.cardBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    metricTile("体感", "\(Int(snapshot.apparentTemperatureCelsius.rounded()))°", "thermometer.medium")
                    metricTile("湿度", "\(Int((snapshot.humidity * 100).rounded()))%", "humidity")
                    metricTile("风速", "\(Int(snapshot.windSpeedKPH.rounded())) km/h", "wind")
                    metricTile("降雨", snapshot.precipitationChance.map { "\(Int(($0 * 100).rounded()))%" } ?? "--", "cloud.rain")
                }

                Text("更新于 \(snapshot.date.formatted(date: .omitted, time: .shortened)) · \(snapshot.attributionServiceName)")
                    .font(.footnote)
                    .foregroundStyle(theme.textTertiary)
                    .onTapGesture {
                        UIApplication.shared.open(snapshot.attributionLegalURL)
                    }
            }
            .padding(20)
        }
        .refreshable {
            await load()
        }
    }

    private func metricTile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(theme.brandPrimary)
            Text(title)
                .font(.caption)
                .foregroundStyle(theme.textSecondary)
            Text(value)
                .font(.headline)
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @MainActor
    private func load() async {
        isLoading = true
        errorMessage = nil
        do {
            snapshot = try await LocalWeatherService.shared.currentWeather()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
