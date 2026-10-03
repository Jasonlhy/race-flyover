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

    /// Course checklist: tick exactly the courses to play.
    private let courseList = NSStackView()
    private var courseChecks: [String: NSButton] = [:]
    private let importButton = NSButton(title: "Import GPX…", target: nil, action: nil)
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
    private let fluidCheck = NSSwitch()
    private let fuelCheck = NSSwitch()
    private let markersCheck = NSSwitch()
    private let burstsCheck = NSSwitch()
    private let landmarksCheck = NSSwitch()
    private let autoTiltCheck = NSSwitch()
    private let frameRatePopup = NSPopUpButton()
    private let displaysPopup = NSPopUpButton()
    private let map3DCheck = NSSwitch()
    private let pinPopup = NSPopUpButton()
    private let pinStylePopup = NSPopUpButton()
    private let pinSizeControl = NSSegmentedControl()
    private let trailPopup = NSPopUpButton()
    private let infoLabel = NSTextField(wrappingLabelWithString: "")

    init(settings: Settings) {
        self.settings = settings
        original = settings.config
        config = original
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
                          styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
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

    // MARK: - Layout (in the style of System Settings: grouped rows, label on the
    // left, control on the right, short notes under each group)

    private let tabs = NSTabView()
    private var sidebarItems: [SidebarItem] = []
    private static let contentWidth: CGFloat = 500

    private struct Page {
        let title: String
        let symbol: String
        let tint: NSColor
        let sections: [NSView]
    }

    private func buildUI() {
        configureControls()
        let pages: [Page] = [
            Page(title: "Courses", symbol: "flag.checkered", tint: .systemBlue, sections: [
                section("Courses", accessory: hstack([quick("All", #selector(selectAllCourses)),
                                                      quick("Majors", #selector(selectMajors)),
                                                      quick("None", #selector(selectNoCourses))]),
                        rows: [courseChooser(), row("Your own race", control: importButton)],
                        footer: infoLabel),
                section(nil, rows: [row("Flyover time", detail: lapLabel, control: lapSlider)],
                        footer: note("About 3–4 hours is close to real race pace.")),
            ]),
            Page(title: "Camera", symbol: "video.fill", tint: .systemGray, sections: [
                section(nil, rows: [
                    row("Camera", control: cameraControl),
                    row("Tilt", detail: tiltLabel, control: tiltSlider),
                    row("Automatic tilt", subtitle: "Steeper among buildings, lower in open areas", control: autoTiltCheck),
                    row("Zoom", detail: zoomLabel, control: zoomSlider),
                ], footer: note("Chase follows the runner and turns with the road. North up never rotates. Overview shows the whole course with a slow orbit.")),
            ]),
            Page(title: "Appearance", symbol: "paintpalette.fill", tint: .systemPurple, sections: [
                section("Visuals", rows: [
                    row("Style", control: stylePopup),
                    row("3D buildings & terrain", subtitle: "Apple Maps styles · uses more power", control: map3DCheck),
                    row("Hill exaggeration", detail: exaggerationLabel, control: exaggerationSlider),
                ], footer: note("Apple Maps styles show real imagery and street names, and need the internet the first time. The other styles work offline.")),
                section("Runner", rows: [
                    row("Pin style", subtitle: PanelStyle.glassAvailable ? nil : "Liquid Glass needs macOS 26", control: pinStylePopup),
                    row("Pin size", control: pinSizeControl),
                    row("Pin colour", control: pinPopup),
                    row("Trail colour", control: trailPopup),
                ], footer: note("The pin shows an arrow for the direction of travel. On Apple Maps the trail colour is used for the route's border.")),
            ]),
            Page(title: "Overlay", symbol: "rectangle.3.group.fill", tint: .systemIndigo, sections: [
                section(nil, rows: [
                    row("Information", control: hudPopup),
                    row("Panels", subtitle: PanelStyle.glassAvailable ? nil : "Liquid Glass needs macOS 26", control: panelPopup),
                    row("Units", control: unitsControl),
                ], footer: note("Full shows the course, distance with minimap, next stations and the elevation profile. Minimal shows just the name, distance and progress.")),
                section("Text", rows: [
                    row("Typeface", control: fontPopup),
                    row("Size", control: sizeControl),
                ], footer: nil),
            ]),
            Page(title: "On the Route", symbol: "mappin.and.ellipse", tint: .systemOrange, sections: [
                section("Stations & markers", rows: [
                    row("Fluid stations", control: fluidCheck),
                    row("Fuel stations", control: fuelCheck),
                    row("Distance markers", control: markersCheck),
                    row("Pulse when passing", control: burstsCheck),
                ], footer: note("The pin sends out a ring as it passes a station, a distance marker or halfway.")),
                section(nil, rows: [row("Landmarks", control: landmarksCheck)],
                        footer: note("Famous sights near the route, found with Apple Maps. The caption under the minimap names them as you pass.")),
            ]),
            Page(title: "Performance", symbol: "gauge.with.dots.needle.67percent", tint: .systemGreen, sections: [
                section(nil, rows: [
                    row("Displays", control: displaysPopup),
                    row("Frame rate", control: frameRatePopup),
                ], footer: note("For the smoothest playback: 30 fps, 3D buildings off, and “Main display only” if you have several screens.")),
            ]),
        ]

        // Sidebar
        var sidebarViews: [NSView] = [spacer(height: 26)]
        for (i, page) in pages.enumerated() {
            let item = SidebarItem(title: page.title, symbol: page.symbol, tint: page.tint) { [weak self] in self?.select(page: i) }
            sidebarItems.append(item)
            sidebarViews.append(item)
        }
        let sidebar = NSStackView(views: sidebarViews)
        sidebar.orientation = .vertical
        sidebar.alignment = .leading
        sidebar.spacing = 2
        sidebar.edgeInsets = NSEdgeInsets(top: 12, left: 10, bottom: 12, right: 10)
        for item in sidebarItems { item.widthAnchor.constraint(equalToConstant: 180).isActive = true }
        let sidebarBackground = NSVisualEffectView()
        sidebarBackground.material = .sidebar
        sidebarBackground.blendingMode = .behindWindow
        sidebarBackground.addSubview(sidebar)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: sidebarBackground.topAnchor),
            sidebar.leadingAnchor.constraint(equalTo: sidebarBackground.leadingAnchor),
            sidebarBackground.widthAnchor.constraint(equalToConstant: 200),
        ])

        // Pages
        tabs.tabViewType = .noTabsNoBorder
        tabs.drawsBackground = false
        for page in pages {
            let heading = NSTextField(labelWithString: page.title)
            heading.font = .systemFont(ofSize: 15, weight: .semibold)
            let stack = NSStackView(views: [heading] + page.sections)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 22
            stack.setCustomSpacing(14, after: heading)
            stack.edgeInsets = NSEdgeInsets(top: 22, left: 24, bottom: 22, right: 24)
            let view = NSView()
            view.addSubview(stack)
            stack.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: view.topAnchor),
                stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            ])
            let item = NSTabViewItem()
            item.view = view
            tabs.addTabViewItem(item)
        }

        // Footer
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let done = NSButton(title: "Done", target: self, action: #selector(done))
        done.keyEquivalent = "\r"
        let defaults = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults))
        defaults.bezelStyle = .push
        let flexible = NSView()
        flexible.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [defaults, flexible, cancel, done])
        footer.orientation = .horizontal
        footer.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 14, right: 20)
        let divider = NSBox()
        divider.boxType = .separator

        let right = NSStackView(views: [tabs, divider, footer])
        right.orientation = .vertical
        right.spacing = 0
        right.alignment = .width
        let root = NSStackView(views: [sidebarBackground, right])
        root.orientation = .horizontal
        root.spacing = 0
        root.alignment = .height

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 748, height: 600))
        content.addSubview(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            root.topAnchor.constraint(equalTo: content.topAnchor),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 748),
            content.heightAnchor.constraint(equalToConstant: 600),
        ])
        window.contentView = content
        window.setContentSize(NSSize(width: 748, height: 600))
        select(page: 0)
    }

    private func select(page: Int) {
        tabs.selectTabViewItem(at: page)
        for (i, item) in sidebarItems.enumerated() { item.isSelected = i == page }
    }

    /// A rounded group of rows with an optional header and a short note beneath.
    private func section(_ header: String?, accessory: NSView? = nil, rows: [NSView], footer: NSView?) -> NSView {
        let box = GroupBox()
        var stacked: [NSView] = []
        for (i, r) in rows.enumerated() {
            if i > 0 {
                let line = NSBox()
                line.boxType = .separator
                stacked.append(line)
            }
            stacked.append(r)
        }
        let inner = NSStackView(views: stacked)
        inner.orientation = .vertical
        inner.alignment = .width
        inner.spacing = 0
        box.addSubview(inner)
        inner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: box.topAnchor),
            inner.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -12),
            box.widthAnchor.constraint(equalToConstant: Self.contentWidth),
        ])
        var views: [NSView] = []
        if header != nil || accessory != nil {
            let title = NSTextField(labelWithString: header ?? "")
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            let flexible = NSView()
            flexible.setContentHuggingPriority(.init(1), for: .horizontal)
            let bar = hstack([title, flexible] + (accessory.map { [$0] } ?? []))
            bar.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
            views.append(bar)
        }
        views.append(box)
        if let footer { views.append(footer) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        return stack
    }

    /// One setting row: name (with an optional subtitle or live value) on the left,
    /// its control on the right.
    private func row(_ title: String, subtitle: String? = nil, detail: NSTextField? = nil, control: NSView) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13)
        var left: [NSView] = [label]
        if let subtitle {
            let sub = NSTextField(labelWithString: subtitle)
            sub.font = .systemFont(ofSize: 11)
            sub.textColor = .secondaryLabelColor
            left.append(sub)
        }
        if let detail { left.append(detail) }
        let text = NSStackView(views: left)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let flexible = NSView()
        flexible.setContentHuggingPriority(.init(1), for: .horizontal)
        let r = hstack([text, flexible, control])
        r.alignment = .centerY
        r.edgeInsets = NSEdgeInsets(top: 9, left: 0, bottom: 9, right: 0)
        r.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        return r
    }

    private func note(_ text: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: text)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        t.preferredMaxLayoutWidth = Self.contentWidth - 8
        t.widthAnchor.constraint(lessThanOrEqualToConstant: Self.contentWidth - 8).isActive = true
        return t
    }

    private func quick(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.controlSize = .small
        b.bezelStyle = .push
        return b
    }

    private func hstack(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func spacer(height: CGFloat) -> NSView {
        let v = NSView()
        v.heightAnchor.constraint(equalToConstant: height).isActive = true
        return v
    }

    private func configureControls() {
        for control in [pinStylePopup, pinSizeControl, stylePopup, hudPopup, fontPopup, panelPopup, frameRatePopup, displaysPopup,
                        pinPopup, trailPopup] as [NSControl] {
            control.target = self
            control.action = #selector(changed)
        }
        for slider in [lapSlider, tiltSlider, zoomSlider, exaggerationSlider] {
            slider.target = self
            slider.action = #selector(changed)
            slider.isContinuous = true
            slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
        }
        for toggle in [fluidCheck, fuelCheck, markersCheck, map3DCheck, burstsCheck, landmarksCheck, autoTiltCheck] {
            toggle.target = self
            toggle.action = #selector(changed)
            toggle.controlSize = .small
        }
        importButton.target = self
        importButton.action = #selector(importGPX)

        pinStylePopup.removeAllItems()
        pinStylePopup.autoenablesItems = false
        for style in PinStyle.allCases {
            pinStylePopup.addItem(withTitle: style.title)
            pinStylePopup.lastItem?.representedObject = style.rawValue
            pinStylePopup.lastItem?.isEnabled = style == .solid || PanelStyle.glassAvailable
        }
        pinSizeControl.segmentCount = PinSize.allCases.count
        for (i, size) in PinSize.allCases.enumerated() { pinSizeControl.setLabel(size.title, forSegment: i) }
        pinSizeControl.trackingMode = .selectOne
        frameRatePopup.removeAllItems()
        frameRatePopup.addItems(withTitles: ["30 fps", "60 fps"])
        displaysPopup.removeAllItems()
        for mode in DisplayMode.allCases {
            displaysPopup.addItem(withTitle: mode.title)
            displaysPopup.lastItem?.representedObject = mode.rawValue
        }
        for popup in [pinPopup, trailPopup] {
            popup.removeAllItems()
            for c in AccentColor.allCases {
                popup.addItem(withTitle: c.title)
                popup.lastItem?.representedObject = c.rawValue
                popup.lastItem?.image = Self.swatch(c)
            }
        }
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
        fontPopup.autoenablesItems = false
        for face in Typeface.allCases {
            fontPopup.addItem(withTitle: face.title)
            fontPopup.lastItem?.representedObject = face.rawValue
            if let family = face.family, NSFontManager.shared.availableMembers(ofFontFamily: family) == nil {
                fontPopup.lastItem?.isEnabled = false
            }
        }
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
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        }
        infoLabel.textColor = .secondaryLabelColor
        infoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        infoLabel.font = .systemFont(ofSize: 11)
        infoLabel.preferredMaxLayoutWidth = Self.contentWidth - 8
    }

    private func courseChooser() -> NSView {
        courseList.orientation = .vertical
        courseList.alignment = .leading
        courseList.spacing = 6
        courseList.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)
        // Fill the row so the checklist starts at the left edge rather than centring.
        courseList.setHuggingPriority(.init(1), for: .horizontal)
        importButton.controlSize = .small
        return courseList
    }

    /// Courses as a two-column checklist per group (flag and name), like a Settings list.
    private func rebuildCourseList() {
        courseList.arrangedSubviews.forEach { $0.removeFromSuperview() }
        courseChecks.removeAll()
        let courses = CourseLibrary.all(settings: settings)
        let selected = CourseLibrary.selectedIDs(config.selection, settings: settings)
        let groups: [(String, [Course])] = [
            ("World Marathon Majors", courses.filter { $0.isMajor && !$0.isImported }),
            ("More marathons", courses.filter { !$0.isMajor && !$0.isImported }),
            ("Your courses", courses.filter(\.isImported)),
        ]
        for (title, list) in groups where !list.isEmpty {
            let header = NSTextField(labelWithString: title.uppercased())
            header.font = .systemFont(ofSize: 10, weight: .semibold)
            header.textColor = .secondaryLabelColor
            if !courseList.arrangedSubviews.isEmpty { courseList.setCustomSpacing(12, after: courseList.arrangedSubviews.last!) }
            courseList.addArrangedSubview(header)
            var cells: [NSView] = []
            for c in list {
                let check = NSButton(checkboxWithTitle: [c.flag, c.name.replacingOccurrences(of: " Marathon", with: "")]
                                        .compactMap { $0 }.joined(separator: "  "),
                                     target: self, action: #selector(changed))
                check.state = selected.contains(c.id) ? .on : .off
                check.toolTip = "\(c.name) — \(c.data.city)"
                courseChecks[c.id] = check
                if c.isImported {
                    let remove = NSButton(title: "Remove", target: self, action: #selector(removeImported(_:)))
                    remove.controlSize = .mini
                    remove.identifier = NSUserInterfaceItemIdentifier(c.id)
                    cells.append(hstack([check, remove]))
                } else {
                    cells.append(check)
                }
            }
            let rows = stride(from: 0, to: cells.count, by: 2).map { i -> [NSView] in
                [cells[i], i + 1 < cells.count ? cells[i + 1] : NSGridCell.emptyContentView]
            }
            let grid = NSGridView(views: rows)
            grid.rowSpacing = 7
            grid.columnSpacing = 24
            grid.column(at: 0).width = 210
            courseList.addArrangedSubview(grid)
        }
    }

    private var checkedIDs: [String] {
        CourseLibrary.all(settings: settings).map(\.id).filter { courseChecks[$0]?.state == .on }
    }

    private func setChecks(_ ids: Set<String>) {
        for (id, check) in courseChecks { check.state = ids.contains(id) ? .on : .off }
        changed()
    }

    @objc private func selectAllCourses() { setChecks(Set(courseChecks.keys)) }
    @objc private func selectMajors() {
        setChecks(Set(CourseLibrary.all(settings: settings).filter(\.isMajor).map(\.id)))
    }
    @objc private func selectNoCourses() { setChecks([]) }

    private func load() {
        rebuildCourseList()
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
        frameRatePopup.selectItem(at: config.smooth60 ? 1 : 0)
        displaysPopup.selectItem(at: DisplayMode.allCases.firstIndex(of: config.displays) ?? 0)
        map3DCheck.state = config.map3D ? .on : .off
        burstsCheck.state = config.showBursts ? .on : .off
        landmarksCheck.state = config.showLandmarks ? .on : .off
        autoTiltCheck.state = config.autoTilt ? .on : .off
        pinPopup.selectItem(at: AccentColor.allCases.firstIndex(of: config.pinColor) ?? 0)
        pinStylePopup.selectItem(at: PinStyle.allCases.firstIndex(of: config.pinStyle) ?? 0)
        pinSizeControl.selectedSegment = PinSize.allCases.firstIndex(of: config.pinSize) ?? 2
        trailPopup.selectItem(at: AccentColor.allCases.firstIndex(of: config.trailColor) ?? 0)
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
        autoTiltCheck.isEnabled = config.camera != .overview
        map3DCheck.isEnabled = config.style.usesTiles

        let ids = checkedIDs
        let courses = CourseLibrary.all(settings: settings)
        if ids.isEmpty {
            infoLabel.stringValue = "No courses ticked — the World Marathon Majors will play."
        } else if ids.count == 1, let c = courses.first(where: { $0.id == ids[0] }) {
            var info = String(format: "%@ · %d fluid · %d fuel stations", c.data.city, c.fluidStations, c.fuelStations)
            if c.data.stationsEstimated == true { info += " (estimated)" }
            infoLabel.stringValue = info
        } else {
            infoLabel.stringValue = "\(ids.count) of \(courses.count) courses ticked; they play in turn."
        }
        if config.style.usesTiles {
            infoLabel.stringValue += "  Apple Maps styles need an internet connection the first time."
        }
    }

    /// Round colour swatch for the pin/trail menus ("Match style" shows a split disc).
    private static func swatch(_ c: AccentColor) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: false) { r in
            let circle = NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1))
            if let color = c.color {
                color.setFill()
                circle.fill()
            } else {
                NSGradient(colors: [Theme.hex(0x5EF0FF), Theme.hex(0xFF3D71)])?.draw(in: circle, angle: 45)
            }
            NSColor.black.withAlphaComponent(0.25).setStroke()
            circle.lineWidth = 1
            circle.stroke()
            return true
        }
    }

    // MARK: - Actions

    @objc private func changed() {
        config.selection = "ids:" + checkedIDs.joined(separator: ",")
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
        config.smooth60 = frameRatePopup.indexOfSelectedItem == 1
        config.displays = DisplayMode(rawValue: displaysPopup.selectedItem?.representedObject as? String ?? "") ?? .same
        config.map3D = map3DCheck.state == .on
        config.showBursts = burstsCheck.state == .on
        config.showLandmarks = landmarksCheck.state == .on
        config.autoTilt = autoTiltCheck.state == .on
        config.pinColor = AccentColor(rawValue: pinPopup.selectedItem?.representedObject as? String ?? "") ?? .auto
        config.pinStyle = PinStyle(rawValue: pinStylePopup.selectedItem?.representedObject as? String ?? "") ?? .glass
        config.pinSize = PinSize.allCases[max(0, pinSizeControl.selectedSegment)]
        config.trailColor = AccentColor(rawValue: trailPopup.selectedItem?.representedObject as? String ?? "") ?? .auto
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
        if let lastID {
            // Tick the new course alongside whatever was already ticked.
            var ids = CourseLibrary.selectedIDs(config.selection, settings: settings)
            ids.insert(lastID)
            config.selection = "ids:" + ids.joined(separator: ",")
        }
        rebuildCourseList()
        changed()
        if !failures.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some files couldn't be imported"
            alert.informativeText = failures.joined(separator: "\n")
            alert.runModal()
        }
    }

    @objc private func removeImported(_ sender: NSButton) {
        guard let id = sender.identifier?.rawValue else { return }
        settings.importedCourses = settings.importedCourses.filter { $0.id != id }
        var ids = CourseLibrary.selectedIDs(config.selection, settings: settings)
        ids.remove(id)
        config.selection = "ids:" + ids.joined(separator: ",")
        rebuildCourseList()
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

/// One row in the Options sidebar: a coloured icon tile and a title, like System Settings.
private final class SidebarItem: NSView {
    private let tile = NSView()
    private let icon = NSImageView()
    private let label: NSTextField
    private let action: () -> Void
    var isSelected = false { didSet { update() } }

    init(title: String, symbol: String, tint: NSColor, action: @escaping () -> Void) {
        label = NSTextField(labelWithString: title)
        self.action = action
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 5
        tile.layer?.backgroundColor = tint.cgColor
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        icon.contentTintColor = .white
        tile.addSubview(icon)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        let stack = NSStackView(views: [tile, label])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 7, bottom: 5, right: 7)
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            tile.widthAnchor.constraint(equalToConstant: 22),
            tile.heightAnchor.constraint(equalToConstant: 22),
            icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        update()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func mouseDown(with event: NSEvent) { action() }
    override func accessibilityPerformPress() -> Bool { action(); return true }

    private func update() {
        layer?.backgroundColor = isSelected ? NSColor.selectedContentBackgroundColor.cgColor : NSColor.clear.cgColor
        label.textColor = isSelected ? .white : .labelColor
    }
}

/// The rounded, lightly filled box that groups setting rows.
private final class GroupBox: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.04).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override var wantsUpdateLayer: Bool { true }
}
