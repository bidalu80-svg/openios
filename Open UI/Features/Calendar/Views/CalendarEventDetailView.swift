import SwiftUI

struct CalendarEventDetailView: View {
    let event: CalendarEvent
    @Bindable var vm: CalendarViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    @State private var showDeleteConfirm = false

    private var displayTitle: String {
        CalendarDisplayLocalizer.eventTitle(event)
    }

    private var calendarName: String {
        CalendarDisplayLocalizer.calendarName(vm.calendars.first(where: { $0.id == event.calendarId }))
    }

    private var calendarColor: Color {
        vm.color(for: event.calendarId)
    }

    private var timeString: String {
        if event.allDay { return "全天" }
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "zh_CN")
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        if let end = event.endAt {
            let startStr = fmt.string(from: event.startAt)
            // Same day: just show times
            let cal = Calendar.current
            if cal.isDate(event.startAt, inSameDayAs: end) {
                let timeFmt = DateFormatter()
                timeFmt.locale = Locale(identifier: "zh_CN")
                timeFmt.dateFormat = "HH:mm"
                return "\(startStr) – \(timeFmt.string(from: end))"
            }
            return "\(startStr) – \(fmt.string(from: end))"
        }
        return fmt.string(from: event.startAt)
    }

    private var reminderLabel: String {
        guard let mins = event.meta?.alertMinutes else { return "" }
        switch mins {
        case 0: return "事件开始时"
        case 5: return "提前 5 分钟"
        case 10: return "提前 10 分钟"
        case 15: return "提前 15 分钟"
        case 30: return "提前 30 分钟"
        case 60: return "提前 1 小时"
        default: return "提前 \(mins) 分钟"
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                theme.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        // Header: title + calendar color strip
                        HStack(spacing: 12) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(calendarColor)
                                .frame(width: 4)
                                .frame(maxHeight: .infinity)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayTitle)
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(theme.textPrimary)

                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(calendarColor)
                                        .frame(width: 8, height: 8)
                                    Text(calendarName)
                                        .font(.subheadline)
                                        .foregroundStyle(theme.textSecondary)
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 20)
                        .padding(.bottom, 16)

                        Divider().background(theme.divider)

                        // Date/Time
                        detailRow(icon: "clock", title: "时间", value: timeString)

                        if event.rrule != nil {
                            Divider().background(theme.divider).padding(.leading, 56)
                            detailRow(icon: "repeat", title: "重复", value: CalendarDisplayLocalizer.recurrence(event.rrule) ?? "")
                        }

                        if let loc = CalendarDisplayLocalizer.location(event.location) {
                            Divider().background(theme.divider).padding(.leading, 56)
                            detailRow(icon: "mappin", title: "地点", value: loc)
                        }

                        if let desc = CalendarDisplayLocalizer.note(event.description) {
                            Divider().background(theme.divider).padding(.leading, 56)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .top, spacing: 16) {
                                    Image(systemName: "doc.text")
                                        .frame(width: 24)
                                        .foregroundStyle(theme.textTertiary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("备注")
                                            .font(.caption)
                                            .foregroundStyle(theme.textTertiary)
                                        Text(desc)
                                            .font(.body)
                                            .foregroundStyle(theme.textPrimary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                            }
                        }

                        if !reminderLabel.isEmpty {
                            Divider().background(theme.divider).padding(.leading, 56)
                            detailRow(icon: "bell", title: "提醒", value: reminderLabel)
                        }

                        // Automation run status
                        if event.isRunEvent, let status = event.meta?.status {
                            Divider().background(theme.divider).padding(.leading, 56)
                            detailRow(
                                icon: status == "success" ? "checkmark.circle.fill" : "xmark.circle.fill",
                                title: "运行状态",
                                value: status == "success" ? "成功" : "失败",
                                valueColor: status == "success" ? .green : .red
                            )
                        }

                        // Delete button (only for non-system, non-run events)
                        if !event.isRunEvent {
                            Divider()
                                .background(theme.divider)
                                .padding(.top, 20)

                            Button {
                                showDeleteConfirm = true
                            } label: {
                                HStack {
                                    Spacer()
                                    Label("删除事件", systemImage: "trash")
                                        .foregroundStyle(.red)
                                    Spacer()
                                }
                                .padding(.vertical, 14)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("事件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(theme.brandPrimary)
                }
            }
            .confirmationDialog(
                "删除“\(displayTitle)”？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("删除事件", role: .destructive) {
                    Task {
                        await vm.deleteEvent(event)
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("此事件将被永久删除。")
            }
        }
    }

    @ViewBuilder
    private func detailRow(
        icon: String,
        title: String,
        value: String,
        valueColor: Color? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(theme.textTertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(theme.textTertiary)
                Text(value)
                    .font(.body)
                    .foregroundStyle(valueColor ?? theme.textPrimary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }
}
