import Cocoa
import Vision
import EventKit

struct Deadline: Codable { var title: String; var due: Date; var fired: [Int] = []; var notes: String?; var done: Bool?
                          var rid: String? }   // rid: the matching item in Reminders

// Text view with a placeholder, for the card's title and notes.
class Box: NSTextView {
    var placeholder = ""
    override func draw(_ r: NSRect) {
        super.draw(r)
        if string.isEmpty {
            (placeholder as NSString).draw(at: NSPoint(x: textContainerInset.width + 5, y: textContainerInset.height),
                                           withAttributes: [.font: font!, .foregroundColor: NSColor.placeholderTextColor])
        }
    }
    override func didChangeText() { super.didChangeText(); needsDisplay = true }
}

class AppDelegate: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".deadlines.json")
    let remindBefore = [86400, 3600, 0]   // remind 1 day before, 1 hour before, and when due
    var list: [Deadline] = []
    var reading = false
    var card: NSPanel?, cardTitle: Box?, cardNotes: Box?
    let store = EKEventStore()
    var remindersList: EKCalendar?

    func applicationDidFinishLaunching(_ n: Notification) {
        if let d = try? Data(contentsOf: file) {
            if let l = try? JSONDecoder().decode([Deadline].self, from: d) {
                list = l
                try? d.write(to: file.appendingPathExtension("backup"), options: .atomic)   // last good copy
            } else {
                // Unreadable file: set it aside instead of overwriting it with an empty list.
                let broken = file.appendingPathExtension("broken")
                try? FileManager.default.removeItem(at: broken)
                try? FileManager.default.moveItem(at: file, to: broken)
                let a = NSAlert(); a.messageText = "Couldn’t read your deadlines"
                a.informativeText = "The file was moved to ~/.deadlines.json.broken. A backup may be at ~/.deadlines.json.backup."
                a.runModal()
            }
        }
        // Menu-bar apps have no main menu, so ⌘C/⌘V/⌘X/⌘A/⌘Z need an (invisible) Edit menu to reach text fields.
        let edit = NSMenu(title: "Edit")
        for (title, sel, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"),
                                  ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(NSMenuItem(title: title, action: Selector(sel), keyEquivalent: key))
        }
        let editItem = NSMenuItem(); editItem.submenu = edit
        NSApp.mainMenu = NSMenu(); NSApp.mainMenu?.addItem(editItem)
        tick()
        store.requestFullAccessToReminders { ok, err in NSLog("DLDEBUG request ok=%d err=%@", ok ? 1 : 0, String(describing: err)); if ok { DispatchQueue.main.async { self.tick() } } }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in self.tick() }
    }

    func oneLine(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ") }
    func short(_ s: String) -> String { s.count > 20 ? s.prefix(20).trimmingCharacters(in: .whitespaces) + "…" : s }

    // "Today 23:55", "Tomorrow 09:00", "Fri 17:00" within a week, else "Fri Oct 23, 17:00".
    func when(_ d: Date) -> String {
        let cal = Calendar.current, df = DateFormatter()
        df.dateFormat = "HH:mm"; let time = df.string(from: d)
        if cal.isDateInToday(d) { return "Today " + time }
        if cal.isDateInTomorrow(d) { return "Tomorrow " + time }
        if d > Date(), d.timeIntervalSinceNow < 6 * 86400 { df.dateFormat = "EEE HH:mm"; return df.string(from: d) }
        df.dateFormat = "EEE MMM d, HH:mm"; return df.string(from: d)
    }

    func save() { try? JSONEncoder().encode(list).write(to: file, options: .atomic) }

    func left(_ d: Date) -> String {
        let s = Int(d.timeIntervalSinceNow)
        if s < 0 { return "overdue" }
        if s >= 86400 { return "\(s / 86400)d \(s % 86400 / 3600)h" }
        if s >= 3600 { return "\(s / 3600)h \(s % 3600 / 60)m" }
        return "\(s / 60)m"
    }

    func tick() {
        list.sort { $0.due < $1.due }
        var missed: [Deadline] = []
        for i in list.indices where list[i].done != true {
            var late = false
            for b in remindBefore where !list[i].fired.contains(b) && list[i].due.timeIntervalSinceNow <= Double(b) {
                list[i].fired.append(b)
                if list[i].due.timeIntervalSinceNow > Double(b) - 600 { remind(list[i]) } else { late = true }
            }
            if late { missed.append(list[i]) }
        }
        syncReminders()
        save()
        if !missed.isEmpty {   // reminders that came due while the Mac was asleep or the app wasn't running
            NSSound(named: "Glass")?.play()
            let a = NSAlert(); a.messageText = "Missed reminders"
            a.informativeText = missed.map { "\(oneLine($0.title)) — \($0.due < Date() ? "overdue" : "due in " + left($0.due))" }
                .joined(separator: "\n")
            a.window.level = .floating
            NSApp.activate(ignoringOtherApps: true)
            a.runModal()
        }
        let f = list.first { $0.done != true }
        let secs = f?.due.timeIntervalSinceNow ?? .infinity
        let img = NSImage(systemSymbolName: secs < 0 ? "exclamationmark.circle" : secs < 86400 ? "hourglass.bottomhalf.filled" : "hourglass",
                          accessibilityDescription: "Deadlines")
        img?.isTemplate = true
        item.button?.image = img
        item.button?.imagePosition = .imageLeading
        item.button?.title = reading ? " Reading screenshot…" : f.map { " \(short(oneLine($0.title))) · \(left($0.due))" } ?? ""
        buildMenu()
    }

    func buildMenu() {
        let menu = NSMenu()
        let completed = NSMenu()
        for (i, d) in list.enumerated() {
            let isDone = d.done == true
            let m = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            let urgent = !isDone && d.due.timeIntervalSinceNow < 86400   // due within a day (or overdue): bold
            m.attributedTitle = NSAttributedString(string: "\(oneLine(d.title)) — \(when(d.due))" + (isDone ? "" : "  (\(left(d.due)))"),
                attributes: [.font: urgent ? NSFont.boldSystemFont(ofSize: NSFont.systemFontSize) : NSFont.menuFont(ofSize: 0)])
            let sub = NSMenu()
            if let note = d.notes?.split(separator: "\n").first {   // notes preview instead of a floating tooltip
                sub.addItem(NSMenuItem(title: note.count > 40 ? note.prefix(40) + "…" : String(note), action: nil, keyEquivalent: ""))
                sub.addItem(.separator())
            }
            for (title, sel, on) in [("Done", #selector(markDone(_:)), isDone), ("Still Doing", #selector(markDoing(_:)), !isDone)] {
                let o = NSMenuItem(title: title, action: sel, keyEquivalent: ""); o.tag = i; o.state = on ? .on : .off; sub.addItem(o)
            }
            sub.addItem(.separator())
            let det = NSMenuItem(title: "Details…", action: #selector(open(_:)), keyEquivalent: ""); det.tag = i; sub.addItem(det)
            if isDone {   // quick delete only for completed tasks
                sub.addItem(.separator())
                let del = NSMenuItem(title: "Delete…", action: #selector(deleteOne(_:)), keyEquivalent: ""); del.tag = i; sub.addItem(del)
            }
            m.submenu = sub
            (isDone ? completed : menu).addItem(m)
        }
        if menu.items.isEmpty { menu.addItem(NSMenuItem(title: "No deadlines", action: nil, keyEquivalent: "")) }
        if !completed.items.isEmpty {
            completed.addItem(.separator())
            completed.addItem(NSMenuItem(title: "Clear All Completed…", action: #selector(clearCompleted), keyEquivalent: ""))
            menu.addItem(.separator())
            let c = NSMenuItem(title: "Completed (\(list.filter { $0.done == true }.count))", action: nil, keyEquivalent: "")
            c.submenu = completed; menu.addItem(c)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Add deadline…", action: #selector(addBlank), keyEquivalent: "n"))
        menu.addItem(NSMenuItem(title: "Add from screenshot…", action: #selector(addFromScreenshot), keyEquivalent: "s"))
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu
    }

    @objc func open(_ s: NSMenuItem) { edit(index: s.tag) }
    @objc func markDone(_ s: NSMenuItem) { list[s.tag].done = true; tick() }
    @objc func markDoing(_ s: NSMenuItem) { list[s.tag].done = nil; tick() }
    @objc func deleteOne(_ s: NSMenuItem) { confirmDelete([s.tag], "Delete “\(oneLine(list[s.tag].title))”?") }
    @objc func clearCompleted() {
        let done = list.indices.filter { list[$0].done == true }
        confirmDelete(done, "Delete \(done.count) completed deadline\(done.count == 1 ? "" : "s")?")
    }
    func confirmDelete(_ indices: [Int], _ question: String) {
        let a = NSAlert(); a.messageText = question; a.informativeText = "This can’t be undone."
        a.addButton(withTitle: "Delete").hasDestructiveAction = true; a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        for i in indices.sorted(by: >) { list.remove(at: i) }
        tick()
    }
    @objc func cardButton(_ b: NSButton) { NSApp.stopModal(withCode: NSApplication.ModalResponse(b.tag)) }

    @objc func addBlank() { edit() }

    @objc func addFromScreenshot() {
        let path = NSTemporaryDirectory() + "deadline-shot.png"
        try? FileManager.default.removeItem(atPath: path)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-i", "-x", path]   // drag to select a region, no shutter sound
        guard (try? p.run()) != nil else { return }
        p.waitUntilExit()
        guard FileManager.default.fileExists(atPath: path) else { return } // cancelled
        reading = true; tick()
        DispatchQueue.global().async {
            let guess = self.askDeepSeek(path) ?? self.localGuess(path)
            DispatchQueue.main.async { self.reading = false; self.tick(); self.edit(title: guess.0, due: guess.1, notes: guess.2) }
        }
    }

    // Ask DeepSeek Harness (signed in with your DeepSeek account, no API key) to read the screenshot.
    func askDeepSeek(_ path: String) -> (String, Date?, String?)? {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let now = df.string(from: Date()) + " " + DateFormatter().weekdaySymbols[Calendar.current.component(.weekday, from: Date()) - 1]
        let prompt = """
            Read the screenshot at \(path). It shows something with a deadline. Now is \(now) (local time). \
            Reply with ONLY a JSON object, no other text: {"title": "short task title in the screenshot's language", \
            "due": "YYYY-MM-DDTHH:mm", "urls": ["every URL or web link visible in the screenshot, exactly as shown"]} in local time. \
            If no time is given use 18:00. If there is no deadline, use null for due. If there are no links, use [] for urls.
            """
        let p = Process(); let pipe = Pipe()
        let home = FileManager.default.homeDirectoryForCurrentUser
        p.executableURL = URL(fileURLWithPath: "/Applications/DeepSeek Harness.app/Contents/Resources/runtime/cli/bin/dsh")
        // The patch switches headless mode from the API-key route to the DeepSeek account route.
        p.arguments = ["--profile", "headless", "--patch", home.appendingPathComponent("Applications/Deadlines/dsh-account.yml").path, prompt]
        p.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        p.standardInput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.standardOutput = pipe
        guard (try? p.run()) != nil else { return nil }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        guard let a = out.firstIndex(of: "{"), let b = out.lastIndex(of: "}"),
              let j = try? JSONSerialization.jsonObject(with: Data(out[a...b].utf8)) as? [String: Any],
              let title = j["title"] as? String else { return nil }
        let urls = (j["urls"] as? [String] ?? []).joined(separator: "\n")
        return (title, (j["due"] as? String).flatMap { df.date(from: $0) }, urls.isEmpty ? nil : urls)
    }

    // Offline fallback: on-device text recognition + date pattern matching.
    func localGuess(_ path: String) -> (String, Date?, String?) {
        guard let img = NSImage(contentsOfFile: path),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return ("", nil, nil) }
        let req = VNRecognizeTextRequest()
        req.recognitionLanguages = ["zh-Hans", "en-US"]
        try? VNImageRequestHandler(cgImage: cg).perform([req])
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        // Find the first date in the text; the title is that line minus the date, else the line above, else the first line.
        let text = lines.joined(separator: "\n")
        let links = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
            .matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }.joined(separator: "\n")
        let urls = links.isEmpty ? nil : links
        let det = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
        for (i, line) in lines.enumerated() {
            guard let m = det.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)), let date = m.date else { continue }
            var title = (line as NSString).replacingCharacters(in: m.range, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
            if title.count < 3 { title = i > 0 ? lines[i - 1] : "" }
            return (title, date, urls)
        }
        return (lines.first ?? "", nil, urls)
    }

    // One card for adding (index nil) and for viewing/editing an existing deadline.
    // Return makes a new line in title and notes; ⌘↩ saves, Esc cancels, Tab switches fields.
    func edit(index: Int? = nil, title: String = "", due: Date? = nil, notes: String? = nil) {
        let old = index.map { list[$0] }
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 240),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true; w.level = .floating
        let v = w.contentView!

        let t = Box(frame: NSRect(x: 15, y: 184, width: 330, height: 28))
        t.placeholder = "What's due?"; t.string = old?.title ?? title
        t.font = .systemFont(ofSize: 17, weight: .semibold); t.drawsBackground = false
        t.isRichText = false; t.isVerticallyResizable = false; t.textContainerInset = NSSize(width: 0, height: 2); t.delegate = self

        let p = NSDatePicker(frame: NSRect(x: 20, y: 150, width: 200, height: 24))
        p.datePickerElements = [.yearMonthDay, .hourMinute]
        p.dateValue = old?.due ?? due ?? Calendar.current.date(bySettingHour: 18, minute: 0, second: 0,
                        of: Date().addingTimeInterval(86400)) ?? Date()
        let c = NSButton(checkboxWithTitle: "Done", target: nil, action: nil)
        c.frame = NSRect(x: 270, y: 152, width: 70, height: 20); c.state = old?.done == true ? .on : .off

        let frame = NSBox(frame: NSRect(x: 20, y: 58, width: 320, height: 82))   // visible field outline
        frame.boxType = .custom; frame.titlePosition = .noTitle; frame.contentViewMargins = .zero
        frame.cornerRadius = 6; frame.borderWidth = 1
        frame.borderColor = .tertiaryLabelColor; frame.fillColor = .quaternaryLabelColor
        let ns = NSScrollView(frame: NSRect(x: 1, y: 1, width: 318, height: 80))
        ns.hasVerticalScroller = true; ns.autohidesScrollers = true; ns.borderType = .noBorder; ns.drawsBackground = false
        frame.contentView?.addSubview(ns)
        let n = Box(frame: ns.contentView.bounds)
        n.placeholder = "Add notes"; n.string = old?.notes ?? notes ?? ""
        n.font = .systemFont(ofSize: 13); n.textContainerInset = NSSize(width: 3, height: 6)
        n.isRichText = false; n.autoresizingMask = .width; n.delegate = self
        n.drawsBackground = false
        ns.documentView = n
        cardNotes = n; linkify(n)

        @discardableResult func button(_ title: String, _ code: Int, _ x: CGFloat) -> NSButton {
            let b = NSButton(title: title, target: self, action: #selector(cardButton(_:)))
            b.tag = code; b.frame = NSRect(x: x, y: 16, width: 80, height: 28); v.addSubview(b); return b
        }
        let save = button(old == nil ? "Add" : "Save", 1, 260)
        save.keyEquivalent = "\r"; save.keyEquivalentModifierMask = .command; save.bezelColor = .controlAccentColor
        button("Cancel", 0, 176).keyEquivalent = "\u{1b}"
        if old != nil { button("Delete", 2, 20).hasDestructiveAction = true }
        [t, p, c, frame].forEach { v.addSubview($0) }

        card = w; cardTitle = t; fitTitle()
        w.center(); NSApp.activate(ignoringOtherApps: true); w.makeKeyAndOrderFront(nil)
        // Put the cursor somewhere visible so Return never lands on a button.
        if old == nil { w.makeFirstResponder(t) } else { w.makeFirstResponder(n); n.moveToEndOfDocument(nil) }
        let r = NSApp.runModal(for: w).rawValue
        w.orderOut(nil); card = nil; cardTitle = nil; cardNotes = nil

        if r == 2, let i = index { return confirmDelete([i], "Delete “\(oneLine(list[i].title))”?") }
        let newTitle = t.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let newNotes = n.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard r == 1, !newTitle.isEmpty else { return }
        var d = old ?? Deadline(title: "", due: p.dateValue)
        d.title = newTitle; d.notes = newNotes.isEmpty ? nil : newNotes
        d.done = c.state == .on ? true : nil
        if old?.due != p.dateValue {   // new or rescheduled: don't fire reminders already in the past
            d.due = p.dateValue
            d.fired = remindBefore.filter { d.due.timeIntervalSinceNow <= Double($0) }
        }
        if let i = index { list[i] = d } else { list.append(d) }
        tick()
    }

    // Grow the card (keeping its top edge) so the whole title is visible.
    func fitTitle() {
        guard let w = card, let t = cardTitle, let lm = t.layoutManager, let tc = t.textContainer else { return }
        lm.ensureLayout(for: tc)
        let h = max(28, ceil(lm.usedRect(for: tc).height) + 4)
        t.frame.size.height = h
        let top = w.frame.maxY
        var f = w.frameRect(forContentRect: NSRect(x: w.frame.minX, y: 0, width: 360, height: 212 + h))
        f.origin.y = top - f.height
        w.setFrame(f, display: true)
    }

    func textDidChange(_ n: Notification) {
        if n.object as? Box === cardTitle { fitTitle() }
        if let t = n.object as? Box, t === cardNotes { linkify(t) }
    }

    // Mark every URL in the notes as a clickable link (clicking opens it in the browser).
    func linkify(_ t: NSTextView) {
        guard let ts = t.textStorage else { return }
        let all = NSRange(location: 0, length: ts.length)
        ts.removeAttribute(.link, range: all)
        let det = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for m in det.matches(in: t.string, range: all) { if let u = m.url { ts.addAttribute(.link, value: u, range: m.range) } }
    }

    func textView(_ v: NSTextView, clickedOnLink link: Any, at i: Int) -> Bool {
        card?.level = .normal   // let the browser come in front of the card
        return false            // default handling opens the link
    }

    func textView(_ v: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertTab(_:)) { v.window?.selectNextKeyView(nil); return true }
        if sel == #selector(NSResponder.insertBacktab(_:)) { v.window?.selectPreviousKeyView(nil); return true }
        return false
    }

    // One-way copy into the "Deadlines" list in Reminders; iCloud carries it to your other devices.
    // Changes made there are overwritten (or the item recreated) to match this app; nothing is read back.
    func syncReminders() {
        NSLog("DLDEBUG auth=%d lists=%@ default=%@", EKEventStore.authorizationStatus(for: .reminder).rawValue, store.calendars(for: .reminder).map { $0.title }, store.defaultCalendarForNewReminders()?.title ?? "nil")
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return }
        if remindersList == nil { remindersList = store.calendars(for: .reminder).first { $0.title == "Deadlines" } }
        if remindersList == nil, let source = store.defaultCalendarForNewReminders()?.source {
            let c = EKCalendar(for: .reminder, eventStore: store); c.title = "Deadlines"; c.source = source
            if (try? store.saveCalendar(c, commit: true)) != nil { remindersList = c }
        }
        guard let cal = remindersList else { return }
        let calendar = Calendar.current
        for i in list.indices {
            let d = list[i]
            let r = d.rid.flatMap { store.calendarItem(withIdentifier: $0) as? EKReminder } ?? EKReminder(eventStore: store)
            let due = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: d.due)
            if r.calendar == cal, r.title == d.title, (r.notes ?? "") == (d.notes ?? ""), r.isCompleted == (d.done == true),
               r.dueDateComponents.flatMap({ calendar.date(from: $0) }) == calendar.date(from: due) { continue }
            r.calendar = cal; r.title = d.title; r.notes = d.notes; r.dueDateComponents = due; r.isCompleted = d.done == true
            if (try? store.save(r, commit: false)) != nil { list[i].rid = r.calendarItemIdentifier }
        }
        try? store.commit()
        // Delete reminders whose deadline was deleted here.
        let keep = Set(list.compactMap { $0.rid })
        store.fetchReminders(matching: store.predicateForReminders(in: [cal])) { rs in
            DispatchQueue.main.async {
                for r in rs ?? [] where !keep.contains(r.calendarItemIdentifier) { try? self.store.remove(r, commit: false) }
                try? self.store.commit()
            }
        }
    }

    func remind(_ d: Deadline) {
        NSSound(named: "Glass")?.play()
        let a = NSAlert(); a.messageText = d.title
        a.informativeText = (d.due < Date().addingTimeInterval(60) ? "Due now!" : "Due in \(left(d.due))")
            + (d.notes.map { "\n\n" + $0 } ?? "")
        a.window.level = .floating
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
