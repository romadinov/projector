# Projector

An MS Project–style planner for macOS, iPad and iPhone. Watch the [2½-minute demo](../../releases/latest) (Projector_demo.mp4). You can:

- build a WBS with summary tasks, milestones and durations
- link tasks finish-to-start, start-to-start, finish-to-finish or start-to-finish, with lag or lead
- schedule them with the critical path method
- assign resources and see who is overallocated
- switch between the Gantt chart and the resource plan
- import and export Microsoft Project XML and Primavera P6 XER files

Projects are `.projector` documents (JSON). Save them in iCloud Drive to work on the same plan from all three devices.

## Build

Requires Xcode 27 (iOS 27 / macOS 27 SDK) and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open Projector.xcodeproj           # schemes: Projector-macOS, Projector-iOS (iPhone + iPad)
swift test --package-path Packages/ProjectorKit   # scheduling engine tests
```

`DEVELOPMENT_TEAM` in `project.yml` is the author's team. To build for your own devices, change it to yours and run `xcodegen generate` again.

A signed, notarized Mac build is attached to each [GitHub release](../../releases). `scripts/release-mac.sh <version>` makes one. It needs a Developer ID certificate and a notarytool keychain profile.

`demo/` holds the scripts that recorded the narrated demo: an XCUITest driver, the narration and the ffmpeg build.

## Features

| | |
|---|---|
| **WBS** | Indent/outdent (⌘] / ⌘[), move up/down (⌥⌘↑/↓), collapse summaries. WBS codes and IDs are generated automatically. |
| **Scheduling** | Forward and backward CPM passes. Total slack, critical path (red), working-day calendar with holidays, Must-Start-On constraint. |
| **Date limits** | Any task or phase can have **Starts after** (earliest start; on a phase it holds back every subtask) and **Finish by** (a deadline). A deadline doesn't move work: it pulls in late dates, so a task that would finish late gets negative slack, turns critical and is flagged red. In the chart, a bracket marks the earliest start and an arrow marks the deadline (green when met, red when missed). |
| **Dependencies** | FS / SS / FF / SF with lag (`3SS+2d`). Links on summary tasks apply to their subtasks. Circular links are rejected. |
| **Editing** | Type into the grid as in MS Project: duration `5d` / `2w` / `4h`, predecessors `3, 5FS+2d`, resources `Ann, Bob[50%]`. Unknown resource names are created automatically. On macOS, drag a bar to move it or drag its right edge to resize it. |
| **Resources** | Resource sheet (max units, rate, group). The **resource plan** is a spreadsheet, like MS Project's Resource Usage view. Each resource has a row with its assignments underneath, and there's a Total row. Columns are days, weeks or months; cells show work hours, % of capacity or FTE. Overallocated cells are red. **Copy Grid** copies it as tab-separated text that pastes into Excel or Numbers. **Level Resources** delays lower-priority tasks to clear the overallocation. |
| **Tracking** | % complete, baseline (set/clear, drawn under the bars), work and cost roll-ups. |
| **Quick Plan** | Jot a whole plan down as text and preview its finish date and critical path live, then apply it. Or press **Plan with Claude** to turn rough notes into a full WBS with estimates, links and assignments. |
| **MS Project & Primavera** | **Import from MS Project or Primavera…** (File menu on the Mac, Tools menu on iPad and iPhone) replaces the plan with a Microsoft Project XML or Primavera P6 XER file; Undo brings the old plan back. **Export** writes either format. See [Exchanging plans](#exchanging-plans-with-ms-project-and-primavera). |
| **Platforms** | macOS (menu commands, multi-select with ⌘/⇧-click, inspector), iPad (full grid and inspector), iPhone (compact grid; tap a row to open the task editor as a sheet). |

## Quick Plan notation

```
# comment
Discovery                                   ← a line with indented lines below it is a phase (summary)
  Kickoff 0d @Priya                          ← 0d = milestone
  Interviews 4d after Kickoff @Priya, @Diego[50%]
  Content audit 3d after Kickoff SS+1d
Build
  Front end 3w after Discovery @Mei_Chen      ← "_" stands for a space in resource names
  QA 1w after Front end, Content audit FF
Launch 0d after QA, 2026-12-01 by 2026-12-18   ← not before Dec 1, deadline Dec 18
```

`after` takes task names (exact match, then prefix, then substring) or line numbers. Link types and lags go after the name, e.g. `SS+2d` or `FF-1d`. A date in the `after` list (`2026-12-01`) is an earliest start, and `by 2026-12-18` is a deadline; both work on phases too. Durations need a unit, so in `Phase 2` the number stays part of the name.

### Plan with Claude

The Quick Plan sheet can send your notes to Claude (`claude-opus-5-5`) through the Messages API. Claude replies in the same notation, so you can review and edit the result before applying it, and **Revert to My Notes** restores what you wrote. Add an API key from console.anthropic.com in the sheet; it is stored in the keychain. When you run Xcode, the `ANTHROPIC_API_KEY` environment variable is used if no key is stored.

## Exchanging plans with MS Project and Primavera

| Format | Open in | Save from |
|---|---|---|
| Microsoft Project XML (`.xml`, MSPDI) | MS Project: **File › Open**, choose *XML Format* | MS Project: **File › Save As › XML Format** |
| Primavera P6 XER (`.xer`) | P6 Professional: **File › Import › Primavera PM (XER)** | P6: **File › Export › Primavera PM (XER)** |

MS Project's own `.mpp` files are a closed binary format; save them as XML in MS Project first.

What carries over in both directions:
- the outline
- durations and milestones
- FS/SS/FF/SF links with lag
- the working week and holidays
- resources with max units and rate
- assignments with units
- % complete
- start limits: *Starts after* ⇄ Start No Earlier Than / Start On or After
- *Must start on* ⇄ Must Start On / Mandatory Start
- deadlines: *Finish by* ⇄ Deadline or Finish No Later Than / Finish On or Before

MS Project XML also carries notes, baselines and leveling delay.

Primavera has no summary activities, so:
- each phase becomes a WBS element and its subtasks the activities under it;
- on export, a phase's links and date limits are applied to each of its subtasks;
- on import, a resource's parent resource becomes its group.

The importer skips, and lists what it skipped:
- other constraint types;
- percentage lags;
- recurring calendar exceptions;
- material and cost resources;
- links to other projects.

When an XER file holds several projects, the one with the most activities is imported.

Both formats are tested against [MPXJ](https://www.mpxj.org), the open-source library most schedule converters use. MPXJ reads Projector's files, and Projector reads files MPXJ writes; the schedule comes out identical. They haven't yet been opened in MS Project or P6 themselves.

## Layout

```
Packages/ProjectorKit/        platform-independent model and engine (unit tested)
  Model.swift                 Project, ProjectTask, Dependency, Resource, Assignment, CalendarSettings
  WorkCalendar.swift          working-day offset ↔ date mapping
  Outline.swift               WBS derived from outline levels
  Scheduler.swift             CPM forward/backward pass, roll-ups, resource loading
  Leveler.swift               resource leveling
  Timephased.swift            work per day / week / month for the resource plan
  Editing.swift               indent/outdent/move/delete/link with validation
  Parsing.swift, QuickPlan.swift   MS Project–style text entry and the Quick Plan notation
  MSProjectXML.swift, PrimaveraXER.swift   import/export (Interchange.swift: format detection, shared helpers)
App/Shared/                   SwiftUI app shared by both targets
  ProjectDocument.swift       Document protocol (iOS/macOS 27), JSON file format
  ProjectController.swift     per-window state; every edit is one undo step (this drives autosave)
  Timeline/                   synced table + timeline split view and date header
  Gantt/, Resources/, Inspectors/, QuickPlan/
```
