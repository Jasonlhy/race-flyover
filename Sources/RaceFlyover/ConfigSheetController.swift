import AppKit
import UniformTypeIdentifiers

/// The Options sheet. Changes apply live (the System Settings thumbnail and the
/// preview app update as you drag); Cancel restores what was there before.
final class ConfigSheetController: NSObject {
    let window: NSWindow
    private let settings: Settings
    private var original: Config
    private var config: Config

    private static let lapSteps: [Double] = [2, 3, 5, 8, 10, 15, 20, 30, 45, 60, 90, 120, 150, 180, 210, 240]

    private let coursePopup = NSPopUpButton()
    private let importButton = NSButton(title: "Import GPX…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let lapSlider = NSSlider()
    private let lapLabel = NSTextField(labelWithString: "")
    private let cameraControl = NSSegmentedControl()
    private let tiltSlider = NSSlider()
    private let tiltLabel = NSTextField(labelWithString: "")
    private let zoomSlider = NSSlider()
    private let zoomLabel = NSTextField(labelWithString: "")
    private let stylePopup = NSPopUpButton()
    private let exaggerationSlider = NSSlider()
    private let exaggerationLabel = NSTextField(labelWithString: "")
    private let unitsControl = NSSegmentedControl()
    private let hudPopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let panelPopup = NSPopUpButton()
    private let sizeControl = NSSegmentedControl()
    private static let textScales: [Double] = [0.8, 1.0, 1.2, 1.4]
    private let fluidCheck = NSButton(checkboxWithTitle: "Fluid stations", target: nil, action: nil)
    private let fuelCheck = NSButton(checkboxWithTitle: "Fuel stations", target: nil, action: nil)
    private let markersCheck = NSButton(checkboxWithTitle: "Distance markers", target: nil, action: nil)
    private let smoothCheck = NSButton(checkboxWithTitle: "Smooth animation (60 fps, uses more power)", target: nil, action: nil)
    private let infoLabel = NSTextField(wrappingLabelWithString: "")

    init(settings: Settings) {
        self.settings = settings
        original = settings.config
        config = original
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 600),
                          styleMask: [.titled], backing: .buffered, defer: false)
        super.init()
        window.title = "Race Flyover Options"
        // Created in code, so AppKit would otherwise free it on close while we
        // still hold it, crashing the host the next time Options is opened.
        window.isReleasedWhenClosed = false
        buildUI()
        load()
    }

    /// Refreshes the controls from saved settings before each presentation.
    func prepare() {
        original = settings.config
        config = original
        load()
    }

    // MARK: - Layout

    private func buildUI() {
        let title = NSTextField(labelWithString: "Race Flyover")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Fly over your race courses, with fluid and fuel stations.")
        subtitle.textColor = .secondaryLabelColor

        for (control, sel) in [(coursePopup, #selector(changed)), (stylePopup, #selector(changed)),
                               (hudPopup, #selector(changed)), (fontPopup, #selector(changed)),
                               (panelPopup, #selector(changed))] as [(NSControl, Selector)] {
            control.target = self
            control.action = sel
        }
        for slider in [lapSlider, tiltSlider, zoomSlider, exaggerationSlider] {
            slider.target = self
            slider.action = #selector(changed)
            slider.isContinuous = true
            slider.controlSize = .regular
            slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        }
        for check in [fluidCheck, fuelCheck, markersCheck, smoothCheck] {
            check.target = self
            check.action = #selector(changed)
        }
        importButton.target = self
        importButton.action = #selector(importGPX)
        removeButton.target = self
        removeButton.action = #selector(removeImported)

        lapSlider.minValue = 0
        lapSlider.maxValue = Double(Self.lapSteps.count - 1)
        lapSlider.numberOfTickMarks = Self.lapSteps.count
        lapSlider.allowsTickMarkValuesOnly = true
        tiltSlider.minValue = 0
        tiltSlider.maxValue = 80
        zoomSlider.minValue = 0
        zoomSlider.maxValue = 1
        exaggerationSlider.minValue = 1
        exaggerationSlider.maxValue = 12

        cameraControl.segmentCount = CameraMode.allCases.count
        for (i, mode) in CameraMode.allCases.enumerated() { cameraControl.setLabel(mode.title, forSegment: i) }
        cameraControl.trackingMode = .selectOne
        cameraControl.target = self
        cameraControl.action = #selector(changed)

        unitsControl.segmentCount = 2
        unitsControl.setLabel("Kilometres", forSegment: 0)
        unitsControl.setLabel("Miles", forSegment: 1)
        unitsControl.trackingMode = .selectOne
        unitsControl.target = self
        unitsControl.action = #selector(changed)

        stylePopup.removeAllItems()
        for style in VisualStyle.allCases {
            stylePopup.addItem(withTitle: style.title)
            stylePopup.lastItem?.representedObject = style.rawValue
            if style == .mapLight { stylePopup.menu?.addItem(.separator()) }
        }
        panelPopup.removeAllItems()
        panelPopup.autoenablesItems = false
        for style in PanelStyle.allCases {
            panelPopup.addItem(withTitle: style.title + (style != .solid && !PanelStyle.glassAvailable ? " (macOS 26+)" : ""))
            panelPopup.lastItem?.representedObject = style.rawValue
            panelPopup.lastItem?.isEnabled = style == .solid || PanelStyle.glassAvailable
        }
        fontPopup.removeAllItems()
        for face in Typeface.allCases {
            fontPopup.addItem(withTitle: face.title)
            fontPopup.lastItem?.representedObject = face.rawValue
            if let family = face.family, NSFontManager.shared.availableMembers(ofFontFamily: family) == nil {
                fontPopup.lastItem?.isEnabled = false
            }
        }
        fontPopup.autoenablesItems = false
        sizeControl.segmentCount = Self.textScales.count
        for (i, title) in ["S", "M", "L", "XL"].enumerated() { sizeControl.setLabel(title, forSegment: i) }
        sizeControl.trackingMode = .selectOne
        sizeControl.target = self
        sizeControl.action = #selector(changed)
        hudPopup.removeAllItems()
        for mode in HUDMode.allCases {
            hudPopup.addItem(withTitle: mode.title)
            hudPopup.lastItem?.representedObject = mode.rawValue
        }

        for label in [lapLabel, tiltLabel, zoomLabel, exaggerationLabel] {
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        infoLabel.preferredMaxLayoutWidth = 400

        func row(_ name: String, _ views: [NSView]) -> [NSView] {
            let label = NSTextField(labelWithString: name)
            label.alignment = .right
            let stack = NSStackView(views: views)
            stack.orientation = .horizontal
            stack.spacing = 8
            stack.alignment = .centerY
            return [label, stack]
        }
        func column(_ views: [NSView]) -> NSStackView {
            let s = NSStackView(views: views)
            s.orientation = .vertical
            s.alignment = .leading
            s.spacing = 2
            return s
        }

        let grid = NSGridView(views: [
            row("Course:", [coursePopup, importButton, removeButton]),
            [NSGridCell.emptyContentView, infoLabel],
            row("Flyover time:", [column([lapSlider, lapLabel])]),
            row("Camera:", [cameraControl]),
            row("Tilt:", [column([tiltSlider, tiltLabel])]),
            row("Zoom:", [column([zoomSlider, zoomLabel])]),
            row("Visuals:", [stylePopup]),
            row("Hill exaggeration:", [column([exaggerationSlider, exaggerationLabel])]),
            row("Overlay:", [hudPopup, unitsControl]),
            row("Panels:", [panelPopup]),
            row("Typeface:", [fontPopup, NSTextField(labelWithString: "Size"), sizeControl]),
            row("Show:", [fluidCheck, fuelCheck, markersCheck]),
            [NSGridCell.emptyContentView, smoothCheck],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 12
        grid.columnSpacing = 10
        grid.rowAlignment = .firstBaseline
        for i in [2, 4, 5, 7] { grid.row(at: i).rowAlignment = .none; grid.row(at: i).yPlacement = .top }

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        let defaults = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        let spacer = NSView()
        let buttons = NSStackView(views: [defaults, spacer, cancel, done])
        buttons.orientation = .horizontal
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let header = column([title, subtitle])
        let root = NSStackView(views: [header, grid, buttons])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 18
        root.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        root.translatesAutoresizingMaskIntoConstraints = false
        buttons.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        let content = NSView()
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
        window.setContentSize(content.fittingSize)
    }

    private func rebuildCoursePopup() {
        coursePopup.removeAllItems()
        func add(_ title: String, _ value: String) {
            coursePopup.addItem(withTitle: title)
            coursePopup.lastItem?.representedObject = value
        }
        add("World Marathon Majors (cycle)", "majors")
        add("All courses (cycle)", "all")
        coursePopup.menu?.addItem(.separator())
        let courses = CourseLibrary.all(settings: settings)
        var lastGroup: Int?
        for c in courses {
            let group = c.isImported ? 2 : (c.isMajor ? 0 : 1)
            if let lastGroup, lastGroup != group { coursePopup.menu?.addItem(.separator()) }
            lastGroup = group
            add(c.name + (c.isImported ? " (imported)" : ""), "course:" + c.id)
        }
        let index = coursePopup.itemArray.firstIndex { ($0.representedObject as? String) == config.selection } ?? 0
        coursePopup.selectItem(at: index)
    }

    private func load() {
        rebuildCoursePopup()
        lapSlider.doubleValue = Double(Self.lapSteps.enumerated().min { abs($0.1 - config.lapMinutes) < abs($1.1 - config.lapMinutes) }!.0)
        cameraControl.selectedSegment = CameraMode.allCases.firstIndex(of: config.camera) ?? 0
        tiltSlider.doubleValue = config.tiltDegrees
        zoomSlider.doubleValue = config.zoom
        stylePopup.selectItem(at: stylePopup.itemArray.firstIndex { ($0.representedObject as? String) == config.style.rawValue } ?? 0)
        exaggerationSlider.doubleValue = config.exaggeration
        unitsControl.selectedSegment = config.units == .km ? 0 : 1
        hudPopup.selectItem(at: HUDMode.allCases.firstIndex(of: config.hud) ?? 0)
        fontPopup.selectItem(at: Typeface.allCases.firstIndex(of: config.typeface) ?? 0)
        panelPopup.selectItem(at: PanelStyle.allCases.firstIndex(of: config.panels) ?? 0)
        sizeControl.selectedSegment = Self.textScales.enumerated().min { abs($0.1 - config.textScale) < abs($1.1 - config.textScale) }!.0
        fluidCheck.state = config.showFluid ? .on : .off
        fuelCheck.state = config.showFuel ? .on : .off
        markersCheck.state = config.showMarkers ? .on : .off
        smoothCheck.state = config.smooth60 ? .on : .off
        updateLabels()
    }

    private func updateLabels() {
        let minutes = config.lapMinutes
        let duration = minutes >= 60 ? String(format: "%d h %02d min", Int(minutes) / 60, Int(minutes) % 60)
                                     : String(format: "%.0f min", minutes)
        let paceSeconds = minutes * 60 / (42.195 / config.units.kmPerUnit)
        lapLabel.stringValue = String(format: "Marathon in %@  ·  %d:%02d /%@ pace", duration,
                                      Int(paceSeconds) / 60, Int(paceSeconds) % 60, config.units.label)
        tiltLabel.stringValue = String(format: "%.0f°  %@", config.tiltDegrees,
                                       config.tiltDegrees < 15 ? "(top-down map)" : (config.tiltDegrees > 60 ? "(low flyover)" : ""))
        let d = config.cameraDistance
        zoomLabel.stringValue = d < 1000 ? String(format: "Camera %.0f m from runner", d)
                                         : String(format: "Camera %.1f km from runner", d / 1000)
        exaggerationLabel.stringValue = String(format: "%.0f× vertical (stylized visuals only)", config.exaggeration)
        exaggerationSlider.isEnabled = !config.style.usesTiles
        zoomSlider.isEnabled = config.camera != .overview

        let selected = coursePopup.selectedItem?.representedObject as? String ?? ""
        let courses = CourseLibrary.all(settings: settings)
        if selected.hasPrefix("course:"), let c = courses.first(where: { "course:" + $0.id == selected }) {
            removeButton.isHidden = !c.isImported
            var info = String(format: "%@ · %d fluid · %d fuel stations", c.data.city, c.fluidStations, c.fuelStations)
            if c.data.stationsEstimated == true { info += " (estimated)" }
            infoLabel.stringValue = info
        } else {
            removeButton.isHidden = true
            let count = CourseLibrary.playlist(for: selected, settings: settings).count
            infoLabel.stringValue = "Plays \(count) courses in turn."
        }
        if config.style.usesTiles {
            infoLabel.stringValue += "\nApple Maps styles need an internet connection the first time (imagery is cached)."
        }
    }

    // MARK: - Actions

    @objc private func changed() {
        config.selection = coursePopup.selectedItem?.representedObject as? String ?? "majors"
        config.lapMinutes = Self.lapSteps[Int(lapSlider.doubleValue.rounded())]
        config.camera = CameraMode.allCases[max(0, cameraControl.selectedSegment)]
        config.tiltDegrees = tiltSlider.doubleValue.rounded()
        config.zoom = zoomSlider.doubleValue
        config.style = VisualStyle(rawValue: stylePopup.selectedItem?.representedObject as? String ?? "") ?? .midnight
        config.exaggeration = exaggerationSlider.doubleValue.rounded()
        config.units = unitsControl.selectedSegment == 1 ? .mi : .km
        config.hud = HUDMode(rawValue: hudPopup.selectedItem?.representedObject as? String ?? "") ?? .full
        config.typeface = Typeface(rawValue: fontPopup.selectedItem?.representedObject as? String ?? "") ?? .system
        config.panels = PanelStyle(rawValue: panelPopup.selectedItem?.representedObject as? String ?? "") ?? .solid
        config.textScale = Self.textScales[max(0, sizeControl.selectedSegment)]
        config.showFluid = fluidCheck.state == .on
        config.showFuel = fuelCheck.state == .on
        config.showMarkers = markersCheck.state == .on
        config.smooth60 = smoothCheck.state == .on
        updateLabels()
        settings.config = config
    }

    @objc private func importGPX() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "gpx") ?? .xml]
        panel.allowsMultipleSelection = true
        panel.message = "Choose a GPX course file. Waypoints named water, aid, gel, etc. become stations."
        // Present as a standalone dialog: a sheet on top of this sheet (which System
        // Settings hosts in another process) is fragile and can take the host down.
        guard panel.runModal() == .OK else { return }
        var imported = settings.importedCourses
        var lastID: String?
        var failures: [String] = []
        for url in panel.urls {
            do {
                let data = try Data(contentsOf: url)
                let course = try GPXImporter.course(fromGPX: data, fileName: url.lastPathComponent)
                imported.removeAll { $0.id == course.id }
                imported.append(course)
                lastID = course.id
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        settings.importedCourses = imported
        if let lastID { config.selection = "course:" + lastID }
        rebuildCoursePopup()
        changed()
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some files couldn't be imported"
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
    }

    @objc private func removeImported() {
        guard let sel = coursePopup.selectedItem?.representedObject as? String, sel.hasPrefix("course:") else { return }
        let id = String(sel.dropFirst("course:".count))
        settings.importedCourses = settings.importedCourses.filter { $0.id != id }
        config.selection = "majors"
        rebuildCoursePopup()
        changed()
    }

    @objc private func restoreDefaults() {
        var fresh = Config()
        if Locale.current.measurementSystem == .us { fresh.units = .mi }
        fresh.selection = config.selection
        config = fresh
        load()
        settings.config = config
    }

    @objc private func cancel() {
        settings.config = original
        close()
    }

    @objc private func done() {
        settings.config = config
        close()
    }

    private func close() {
        window.makeFirstResponder(nil)
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            NSApp.endSheet(window)
            window.orderOut(nil)
        }
    }
}
