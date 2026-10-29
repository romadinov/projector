import SwiftUI
import ProjectorKit

/// Project Information and the working calendar.
struct ProjectSettingsView: View {
    let controller: ProjectController
    @Environment(\.dismiss) private var dismiss
    @State private var newHoliday = Date.now

    var body: some View {
        let project = controller.project
        let schedule = controller.schedule
        NavigationStack {
            Form {
                Section("Project") {
                    LabeledContent("Name") {
                        CommitTextField(value: project.name, placeholder: "Project name") { v in
                            controller.edit("Rename Project") { $0.name = v }
                        }.multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Manager") {
                        CommitTextField(value: project.manager, placeholder: "Name") { v in
                            controller.edit("Change Manager") { $0.manager = v }
                        }.multilineTextAlignment(.trailing)
                    }
                    DatePicker("Start date", selection: Binding(
                        get: { project.startDate },
                        set: { d in controller.edit("Change Start Date") { $0.startDate = Calendar.current.startOfDay(for: d) } }),
                               displayedComponents: .date)
                    LabeledContent("Finish date", value: schedule.projectFinish.formatted(date: .abbreviated, time: .omitted))
                    LabeledContent("Duration", value: Notation.formatDuration(schedule.durationDays))
                    LabeledContent("Work", value: "\(Notation.formatNumber(schedule.totalWork)) h")
                    LabeledContent("Cost", value: schedule.totalCost.formatted(.currency(code: project.currencyCode)))
                    Picker("Currency", selection: Binding(
                        get: { project.currencyCode },
                        set: { c in controller.edit("Change Currency") { $0.currencyCode = c } })) {
                        ForEach(["USD", "EUR", "GBP", "AUD", "CAD", "NZD", "JPY", "INR", "SGD", "CHF"], id: \.self) { Text($0).tag($0) }
                    }
                }

                Section("Working time") {
                    Stepper("Hours per day: \(Notation.formatNumber(project.calendar.hoursPerDay))", value: Binding(
                        get: { project.calendar.hoursPerDay },
                        set: { h in controller.edit("Change Hours per Day") { $0.calendar.hoursPerDay = h } }),
                            in: 1...24, step: 0.5)
                    let symbols = Calendar.current.weekdaySymbols
                    let order = (0..<7).map { (Calendar.current.firstWeekday - 1 + $0) % 7 + 1 }
                    ForEach(order, id: \.self) { weekday in
                        Toggle(symbols[weekday - 1], isOn: Binding(
                            get: { project.calendar.workingWeekdays.contains(weekday) },
                            set: { on in controller.edit("Change Working Days") { p in
                                if on { p.calendar.workingWeekdays.insert(weekday) }
                                else if p.calendar.workingWeekdays.count > 1 { p.calendar.workingWeekdays.remove(weekday) }
                            } }))
                    }
                }

                Section("Holidays") {
                    ForEach(project.calendar.holidays.sorted(), id: \.self) { day in
                        HStack {
                            Text(day.formatted(date: .complete, time: .omitted))
                            Spacer()
                            Button(role: .destructive) {
                                controller.edit("Remove Holiday") { $0.calendar.holidays.removeAll { $0 == day } }
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack {
                        DatePicker("Add", selection: $newHoliday, displayedComponents: .date)
                        Button("Add Holiday") {
                            let day = Calendar.current.startOfDay(for: newHoliday)
                            controller.edit("Add Holiday") { p in
                                if !p.calendar.holidays.contains(day) { p.calendar.holidays.append(day) }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Project Information")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 560)
        #endif
    }
}
