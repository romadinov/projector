import Foundation

extension Project {
    /// A small but realistic plan that exercises summaries, every link type, milestones and an overallocation.
    public static func sample(startingOn start: Date = .now, calendar: Calendar = .current) -> Project {
        // Start on the Monday of the current week.
        let day = calendar.startOfDay(for: start)
        let weekday = calendar.component(.weekday, from: day)
        let monday = calendar.date(byAdding: .day, value: -((weekday + 5) % 7), to: day)!

        var p = Project(name: "Website Relaunch", manager: "Project Manager", startDate: monday)
        let pm = Resource(name: "Priya Shah", group: "Management", standardRate: 120)
        let designer = Resource(name: "Diego Alvarez", group: "Design", standardRate: 95)
        let dev1 = Resource(name: "Mei Chen", group: "Engineering", standardRate: 110)
        let dev2 = Resource(name: "Tom Okafor", group: "Engineering", maxUnits: 0.5, standardRate: 100)
        let qa = Resource(name: "Sara Lind", group: "Quality", standardRate: 80)
        p.resources = [pm, designer, dev1, dev2, qa]

        var rows: [ProjectTask] = []
        func add(_ name: String, _ level: Int, _ duration: Double = 1) -> UUID {
            let t = ProjectTask(name: name, outlineLevel: level, duration: duration)
            rows.append(t)
            return t.id
        }
        func assign(_ task: UUID, _ resource: Resource, _ units: Double = 1) {
            p.assignments.append(Assignment(taskID: task, resourceID: resource.id, units: units))
        }
        func link(_ a: UUID, _ b: UUID, _ type: DependencyType = .finishToStart, lag: Double = 0) {
            p.dependencies.append(Dependency(predecessorID: a, successorID: b, type: type, lag: lag))
        }

        _ = add("Discovery", 1)
        let kickoff = add("Kickoff", 2, 0)
        let interviews = add("Stakeholder interviews", 2, 4)
        let audit = add("Content audit", 2, 3)
        let requirements = add("Requirements sign-off", 2, 1)
        let design = add("Design", 1)
        let ia = add("Information architecture", 2, 3)
        let wireframes = add("Wireframes", 2, 5)
        let visual = add("Visual design", 2, 6)
        let designApproved = add("Design approved", 2, 0)
        let build = add("Build", 1)
        _ = add("Front end", 2)
        let components = add("Component library", 3, 8)
        let pages = add("Page templates", 3, 6)
        let cms = add("CMS integration", 2, 7)
        let migration = add("Content migration", 2, 5)
        let launch = add("Launch", 1)
        let testing = add("QA & accessibility testing", 2, 6)
        let uat = add("User acceptance testing", 2, 4)
        let golive = add("Go live", 2, 0)
        p.tasks = rows

        // Date limits: the CMS licence starts on a Thursday, and design and go-live have deadlines.
        func setDates(_ id: UUID, startAfter: Int? = nil, finishBy: Int? = nil) {
            guard let i = p.tasks.firstIndex(where: { $0.id == id }) else { return }
            p.tasks[i].startAfter = startAfter.flatMap { calendar.date(byAdding: .day, value: $0, to: monday) }
            p.tasks[i].finishBy = finishBy.flatMap { calendar.date(byAdding: .day, value: $0, to: monday) }
        }
        setDates(cms, startAfter: 24)
        setDates(design, finishBy: 22)
        setDates(golive, finishBy: 49)

        link(kickoff, interviews)
        link(kickoff, audit, .startToStart, lag: 1)
        link(interviews, requirements)
        link(audit, requirements)
        link(requirements, design)
        link(ia, wireframes)
        link(wireframes, visual, .startToStart, lag: 3)
        link(visual, designApproved)
        link(designApproved, components)
        link(components, pages, .startToStart, lag: 3)
        link(designApproved, cms)
        link(cms, migration)
        link(pages, testing)
        link(migration, testing, .finishToFinish)
        link(testing, uat)
        link(uat, golive)
        _ = build; _ = launch

        assign(kickoff, pm)
        assign(interviews, pm)
        assign(interviews, designer, 0.5)
        assign(audit, designer)
        assign(requirements, pm)
        assign(ia, designer)
        assign(wireframes, designer)
        assign(visual, designer)
        assign(components, dev1)
        assign(pages, dev1)
        assign(pages, dev2, 0.5)
        assign(cms, dev2, 0.5)
        assign(migration, qa, 0.5)
        assign(migration, dev1, 0.5)
        assign(testing, qa)
        assign(uat, pm, 0.5)
        assign(uat, qa)
        assign(golive, pm)
        return p
    }
}
