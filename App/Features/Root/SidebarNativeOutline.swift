import AppKit
import SwiftUI
import QuartzCore
import StacklumeDesignSystem

@MainActor struct SidebarNativeOutline: NSViewRepresentable {
    var snapshot: SidebarSnapshot
    @Binding var selection: NavTarget?
    var topInset: CGFloat
    var bottomInset: CGFloat
    var perform: @MainActor (SidebarAction) -> Void
    var acceptDrop: @MainActor (String, SidebarDrop) -> Bool
    var setGroupExpanded: @MainActor (SidebarGroupID, Bool) -> Void
    @Environment(\.themePalette) private var palette
    @Environment(\.stacklumeTextScale) private var textScale
    @Environment(\.fontResolutionContext) private var fontContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func makeCoordinator() -> SidebarOutlineCoordinator { SidebarOutlineCoordinator() }
    func makeNSView(context: Context) -> SidebarOutlineScrollView {
        let scroll = SidebarOutlineScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.automaticallyAdjustsContentInsets = false
        let outline = SidebarOwnedOutline()
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.gridStyleMask = []
        outline.intercellSpacing = .zero
        outline.usesAutomaticRowHeights = false
        outline.rowSizeStyle = .custom
        outline.allowsEmptySelection = true
        outline.allowsMultipleSelection = false
        outline.selectionHighlightStyle = .none
        outline.indentationPerLevel = DesignSystem.Spacing.md
        outline.indentationMarkerFollowsCell = true
        outline.autoresizesOutlineColumn = false
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = []
        column.minWidth = 1
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.registerForDraggedTypes([.string])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask(.copy, forLocal: false)
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.owner = context.coordinator
        outline.target = context.coordinator
        outline.action = #selector(SidebarOutlineCoordinator.clicked(_:))
        outline.doubleAction = #selector(SidebarOutlineCoordinator.doubleClicked(_:))
        scroll.documentView = outline
        scroll.owner = context.coordinator
        context.coordinator.outline = outline
        context.coordinator.scroll = scroll
        updateNSView(scroll, context: context)
        return scroll
    }
    func updateNSView(_ view: SidebarOutlineScrollView, context: Context) {
        let insets = NSEdgeInsets(top: max(0, topInset), left: 0, bottom: max(0, bottomInset), right: 0)
        let current = view.contentInsets
        if current.top != insets.top || current.bottom != insets.bottom || current.left != 0 || current.right != 0 {
            view.contentInsets = insets
        }
        let binding = $selection
        context.coordinator.perform = perform
        context.coordinator.acceptDrop = acceptDrop
        context.coordinator.setGroupExpanded = setGroupExpanded
        context.coordinator.setSelection = { binding.wrappedValue = $0 }
        context.coordinator.update(snapshot, selection: selection, palette: palette,
                                   typography: SidebarNativeTypography(context: fontContext, factor: StacklumeTextScale.normalizedFactor(textScale)),
                                   reduceMotion: reduceMotion, reduceTransparency: reduceTransparency)
    }
    static func dismantleNSView(_ view: SidebarOutlineScrollView, coordinator: SidebarOutlineCoordinator) {
        view.setSoftEdges(enabled: false)
        coordinator.dismantle()
        view.owner = nil
    }
}

@MainActor final class SidebarOutlineItem: NSObject {
    let id: SidebarNodeID
    init(_ id: SidebarNodeID) { self.id = id }
}

@MainActor final class SidebarOutlineCoordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var outline: SidebarOwnedOutline?
    weak var scroll: SidebarOutlineScrollView?
    var perform: (@MainActor (SidebarAction) -> Void)?
    var acceptDrop: (@MainActor (String, SidebarDrop) -> Bool)?
    var setGroupExpanded: (@MainActor (SidebarGroupID, Bool) -> Void)?
    var setSelection: (@MainActor (NavTarget?) -> Void)?
    private(set) var snapshot: SidebarSnapshot?
    private(set) var layouts: [SidebarNodeID: SidebarRowLayout] = [:]
    private var keys: [SidebarNodeID: SidebarMetricKey] = [:]
    private var items: [SidebarNodeID: SidebarOutlineItem] = [:]
    private var branches: Set<SidebarNodeID> = []
    private var revealedGroups: Set<SidebarGroupID> = []
    private var revealTask: Task<Void, Never>?
    private var synchronizing = false
    private var collapsing = 0
    private var selected: NavTarget?
    private var focusedGroup: SidebarGroupID?
    private var typography: SidebarNativeTypography?
    private var palette: ThemePalette?
    private var reduceMotion = false
    private var reduceTransparency = false
    private var pendingDrop: SidebarDrop?
    private var metricWidth: CGFloat = 0
    private var metricPalette: ThemePalette?
    private var tooltip: NSPopover?
    private var tooltipTask: Task<Void, Never>?
    private var menuTokens: [SidebarMenuTarget] = []
    private var attachedSession: NativeScrollObservation?

    func update(_ next: SidebarSnapshot, selection: NavTarget?, palette: ThemePalette,
                typography: SidebarNativeTypography, reduceMotion: Bool, reduceTransparency: Bool) {
        guard let outline else { return }
        let structural = snapshot.map { !next.sameStructure(as: $0) } ?? true
        let old = snapshot
        let previousSelection = selected
        self.palette = palette; self.typography = typography
        self.reduceMotion = reduceMotion; self.reduceTransparency = reduceTransparency
        selected = selection
        items = items.filter { next.nodes[$0.key] != nil }
        for id in next.nodes.keys where items[id] == nil { items[id] = SidebarOutlineItem(id) }
        branches = branches.filter { next.nodes[$0] != nil }
        for group in [SidebarGroupID.collections, .tags, .filters, .saved, .tools] {
            if old?.expandedGroups.contains(group) != next.expandedGroups.contains(group) { revealedGroups.remove(group) }
        }
        snapshot = next
        let changed = makeMetrics(width: max(1, scroll?.contentSize.width ?? 1))
        synchronizing = true
        if structural { outline.reloadData() }
        synchronizeExpansion()
        if !structural && !changed.isEmpty {
            let indexes = IndexSet(changed.compactMap { id in
                guard let item = items[id] else { return nil }
                let index = outline.row(forItem: item)
                return index >= 0 ? index : nil
            })
            outline.noteHeightOfRows(withIndexesChanged: indexes)
        }
        let reveal = old == nil || selection != previousSelection
        synchronizeSelection(reveal: reveal)
        synchronizing = false
        if reveal { synchronizeRevealedPreferences() }
        updateVisibleCells()
        scroll?.setSoftEdges(enabled: !reduceTransparency)
    }

    @discardableResult private func makeMetrics(width: CGFloat) -> Set<SidebarNodeID> {
        guard let snapshot, let typography, let palette, let outline else { return [] }
        let backing = outline.window?.backingScaleFactor ?? 2
        let paletteChanged = metricPalette != palette
        let columnWidth = width
        var nextKeys: [SidebarNodeID: SidebarMetricKey] = [:]
        var nextLayouts: [SidebarNodeID: SidebarRowLayout] = [:]
        var changed: Set<SidebarNodeID> = []
        for (id, row) in snapshot.nodes {
            let key = SidebarMetricKey(row, width: columnWidth, depth: snapshot.depths[id] ?? 0,
                                       backingScale: backing, fonts: typography)
            nextKeys[id] = key
            if keys[id] == key, let cached = layouts[id], !paletteChanged { nextLayouts[id] = cached }
            else {
                nextLayouts[id] = SidebarRowLayout.make(row, width: columnWidth, depth: snapshot.depths[id] ?? 0,
                                                       backingScale: backing, fonts: typography, palette: palette)
            }
            if keys[id] != key { changed.insert(id) }
        }
        metricPalette = palette
        keys = nextKeys; layouts = nextLayouts; metricWidth = width
        outline.tableColumns.first?.width = columnWidth
        outline.frame.size.width = columnWidth
        return changed
    }

    func viewportChanged() {
        guard let scroll, let outline, snapshot != nil, !synchronizing else { return }
        let width = max(1, scroll.contentSize.width)
        guard abs(width - metricWidth) >= 0.25 else { return }
        let changed = makeMetrics(width: width)
        let indexes = IndexSet(changed.compactMap { id in
            guard let item = items[id] else { return nil }
            let row = outline.row(forItem: item); return row >= 0 ? row : nil
        })
        outline.noteHeightOfRows(withIndexesChanged: indexes)
        updateVisibleCells()
    }
    func backingChanged() {
        metricWidth = 0
        viewportChanged()
    }

    private func synchronizeExpansion() {
        guard let snapshot, let outline else { return }
        for group in [SidebarGroupID.collections, .tags, .filters, .saved, .tools] {
            let id = SidebarNodeID.group(group)
            guard let item = items[id] else { continue }
            if snapshot.expandedGroups.contains(group) || revealedGroups.contains(group) { outline.expandItem(item) }
            else { outline.collapseItem(item) }
        }
        for id in branches { if let item = items[id] { outline.expandItem(item) } }
    }
    private func synchronizeSelection(reveal: Bool) {
        guard let outline, let snapshot else { return }
        if reveal { focusedGroup = nil }
        if let focusedGroup, let item = items[.group(focusedGroup)] {
            let row = outline.row(forItem: item)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                return
            }
            self.focusedGroup = nil
        }
        guard let selected, let item = items[.destination(selected)] else {
            outline.deselectAll(nil); return
        }
        if reveal {
            for parent in snapshot.ancestors(of: item.id) {
                if case .group(let group) = parent { revealedGroups.insert(group) }
                else { branches.insert(parent) }
                if let parentItem = items[parent] { outline.expandItem(parentItem) }
            }
        }
        let row = outline.row(forItem: item)
        if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        else { outline.deselectAll(nil) }
    }
    private func synchronizeRevealedPreferences() {
        revealTask?.cancel()
        let expected = selected
        revealTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.selected == expected, let snapshot = self.snapshot else { return }
            for group in self.revealedGroups where !snapshot.expandedGroups.contains(group) {
                guard let item = self.items[.group(group)], self.outline?.isItemExpanded(item) == true else { continue }
                self.setGroupExpanded?(group, true)
            }
            self.revealTask = nil
        }
    }
    func isSelected(_ id: SidebarNodeID) -> Bool {
        guard let outline, let item = items[id] else { return false }
        let index = outline.row(forItem: item)
        return index >= 0 && outline.isRowSelected(index)
    }
    private func updateVisibleCells() {
        guard let outline, let snapshot, let palette, let typography else { return }
        let range = outline.rows(in: outline.visibleRect)
        guard range.location != NSNotFound else { return }
        for row in range.location..<min(outline.numberOfRows, NSMaxRange(range)) {
            guard let item = outline.item(atRow: row) as? SidebarOutlineItem,
                  let descriptor = snapshot.nodes[item.id], let layout = layouts[item.id],
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarOutlineCell else { continue }
            cell.configure(descriptor, layout: layout, palette: palette, typography: typography,
                           reduceMotion: reduceMotion, owner: self)
            if let rowView = outline.rowView(atRow: row, makeIfNecessary: false) as? SidebarOutlineRow {
                rowView.accent = NSColor(palette.accent)
                rowView.selectionBase = NSColor(palette.surface)
                rowView.selectionBackground = SidebarSelectionPaint(palette: palette).background
                rowView.needsDisplay = true
            }
        }
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let item = item as? SidebarOutlineItem { return snapshot?.nodes[item.id]?.children.count ?? 0 }
        return snapshot?.roots.count ?? 0
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        let ids = (item as? SidebarOutlineItem).flatMap { snapshot?.nodes[$0.id]?.children } ?? snapshot?.roots ?? []
        return items[ids[index]]!
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let item = item as? SidebarOutlineItem else { return false }
        return snapshot?.nodes[item.id]?.kind == .group || !(snapshot?.nodes[item.id]?.children.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        guard let item = item as? SidebarOutlineItem, let height = layouts[item.id]?.height else { return 1 }
        return height
    }
    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let item = item as? SidebarOutlineItem else { return false }
        guard let row = snapshot?.nodes[item.id] else { return false }
        return row.kind == .group || row.target != nil || row.action != nil
    }
    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { false }
    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        guard let item = item as? SidebarOutlineItem else { return nil }
        return snapshot?.nodes[item.id]?.title
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarOutlineItem, let descriptor = snapshot?.nodes[item.id],
              let layout = layouts[item.id], let palette, let typography else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("sidebar-cell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: self) as? SidebarOutlineCell ?? SidebarOutlineCell()
        cell.identifier = identifier
        cell.configure(descriptor, layout: layout, palette: palette, typography: typography,
                       reduceMotion: reduceMotion, owner: self)
        return cell
    }
    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = SidebarOutlineRow()
        row.backgroundColor = .clear
        row.accent = palette.map { NSColor($0.accent) } ?? .controlAccentColor
        row.selectionBase = palette.map { NSColor($0.surface) } ?? .windowBackgroundColor
        row.selectionBackground = palette.map { SidebarSelectionPaint(palette: $0).background }
        return row
    }
    func outlineViewSelectionDidChange(_ notification: Notification) {
        updateVisibleCells()
        guard !synchronizing, let outline, outline.selectedRow >= 0,
              let item = outline.item(atRow: outline.selectedRow) as? SidebarOutlineItem else { return }
        if case .group(let group) = item.id { focusedGroup = group }
        else { focusedGroup = nil }
        guard collapsing == 0, let target = snapshot?.nodes[item.id]?.target else { return }
        selected = target; setSelection?(target)
    }
    func outlineViewItemDidExpand(_ notification: Notification) { expansion(notification, open: true) }
    func outlineViewItemWillCollapse(_ notification: Notification) { collapsing += 1 }
    func outlineViewItemDidCollapse(_ notification: Notification) {
        defer { collapsing = max(0, collapsing - 1) }
        expansion(notification, open: false)
    }
    private func expansion(_ notification: Notification, open: Bool) {
        guard !synchronizing, let item = notification.userInfo?["NSObject"] as? SidebarOutlineItem else { return }
        if case .group(let group) = item.id {
            revealedGroups.remove(group)
            setGroupExpanded?(group, open)
        }
        else if open { branches.insert(item.id) } else { branches.remove(item.id) }
        synchronizing = true; synchronizeSelection(reveal: false); synchronizing = false
    }
    @objc func clicked(_ sender: NSOutlineView) {
        guard sender.clickedRow >= 0, let item = sender.item(atRow: sender.clickedRow) as? SidebarOutlineItem,
              let row = snapshot?.nodes[item.id] else { return }
        if let action = row.action { perform?(action) }

    }
    func toggle(_ id: SidebarNodeID) {
        guard let outline, let item = items[id] else { return }
        if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) }
    }
    func activateSelectedAction() -> Bool {
        guard let outline, outline.selectedRow >= 0,
              let item = outline.item(atRow: outline.selectedRow) as? SidebarOutlineItem,
              let action = snapshot?.nodes[item.id]?.action else { return false }
        perform?(action); return true
    }
    @objc func doubleClicked(_ sender: NSOutlineView) {
        guard sender.clickedRow >= 0, let item = sender.item(atRow: sender.clickedRow) as? SidebarOutlineItem,
              let row = snapshot?.nodes[item.id], let id = row.dragUUID else { return }
        perform?(.beginRename(id))
    }

    func menu(for item: SidebarOutlineItem) -> NSMenu? {
        guard let entries = snapshot?.nodes[item.id]?.menu, !entries.isEmpty else { return nil }
        menuTokens.removeAll()
        return buildMenu(entries)
    }
    func buildMenu(_ entries: [SidebarMenuEntry]) -> NSMenu {
        let menu = NSMenu(); menu.autoenablesItems = false
        for entry in entries {
            if entry.separator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.isEnabled = entry.enabled; item.state = entry.checked ? .on : .off
            if let symbol = entry.symbol { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
            if let action = entry.action {
                let token = SidebarMenuTarget(owner: self, action: action)
                menuTokens.append(token); item.target = token; item.action = #selector(SidebarMenuTarget.invoke(_:))
            }
            if !entry.children.isEmpty { item.submenu = buildMenu(entry.children) }
            menu.addItem(item)
        }
        return menu
    }
    func accessory(_ accessory: SidebarAccessory, view: NSView) {
        hideTooltip()
        if let action = accessory.action { perform?(action) }
        else if !accessory.menu.isEmpty {
            menuTokens.removeAll()
            buildMenu(accessory.menu).popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.maxY), in: view)
        }
    }

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let item = item as? SidebarOutlineItem, let id = snapshot?.nodes[item.id]?.dragUUID else { return nil }
        let writer = NSPasteboardItem(); writer.setString(id.uuidString, forType: .string); return writer
    }
    func dropProposal(item: Any?, index: Int) -> SidebarDrop? {
        guard let snapshot else { return nil }
        if index == NSOutlineViewDropOnItemIndex, let item = item as? SidebarOutlineItem {
            return SidebarDrop(target: item.id, position: .on)
        }
        let children = (item as? SidebarOutlineItem).flatMap { snapshot.nodes[$0.id]?.children } ?? snapshot.roots
        if index >= 0 && index < children.count { return SidebarDrop(target: children[index], position: .before) }
        if index == children.count, let last = children.last { return SidebarDrop(target: last, position: .after) }
        return nil
    }
    func outlineView(_ outlineView: NSOutlineView, validateDrop info: any NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        pendingDrop = nil
        guard let payload = info.draggingPasteboard.string(forType: .string),
              let drop = dropProposal(item: item, index: index), snapshot?.allows(payload, drop: drop) == true else { return [] }
        pendingDrop = drop
        return payload.hasPrefix("bm:") ? .copy : .move
    }
    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: any NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        defer { pendingDrop = nil }
        guard let payload = info.draggingPasteboard.string(forType: .string),
              let drop = dropProposal(item: item, index: index), snapshot?.allows(payload, drop: drop) == true else { return false }
        return acceptDrop?(payload, drop) ?? false
    }

    func windowChanged() {
        guard let outline else { return }
        if outline.window != nil {
            if attachedSession == nil, let session = ScrollDiagnostics.observation {
                attachedSession = session; session.attach(.sidebar, anchor: outline)
            }
        } else {
            attachedSession?.detach(.sidebar, anchor: outline); attachedSession = nil
            hideTooltip()
        }
    }
    func showTooltip(_ title: String, in view: NSView) {
        hideTooltip()
        guard let palette else { return }
        tooltipTask = Task { @MainActor [weak self, weak view] in
            try? await Task.sleep(for: .milliseconds(480))
            guard !Task.isCancelled, let self, let view, view.window != nil else { return }
            let content = SidebarTooltipView(title: title, palette: palette)
            let controller = NSViewController(); controller.view = content
            let popover = NSPopover(); popover.behavior = .transient
            popover.animates = !self.reduceMotion; popover.contentViewController = controller
            self.tooltip = popover
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        }
    }
    func hideTooltip() { tooltipTask?.cancel(); tooltipTask = nil; tooltip?.close(); tooltip = nil }
    func dismantle() {
        hideTooltip(); menuTokens.removeAll(); revealTask?.cancel(); revealTask = nil
        if let outline {
            attachedSession?.detach(.sidebar, anchor: outline); attachedSession = nil
            let range = outline.rows(in: outline.visibleRect)
            if range.location != NSNotFound {
                for index in range.location..<min(outline.numberOfRows, NSMaxRange(range)) {
                    (outline.view(atColumn: 0, row: index, makeIfNecessary: false) as? SidebarOutlineCell)?.disconnect()
                }
            }
            outline.target = nil; outline.owner = nil; outline.dataSource = nil; outline.delegate = nil
        }
        perform = nil; acceptDrop = nil; setGroupExpanded = nil; setSelection = nil
        snapshot = nil; layouts.removeAll(); keys.removeAll(); items.removeAll(); branches.removeAll(); revealedGroups.removeAll()
    }
}

extension SidebarSnapshot {
    func allows(_ payload: String, drop: SidebarDrop) -> Bool {
        guard nodes[drop.target] != nil else { return false }
        if let bookmarkID = BookmarkTransfer.bookmarkID(from: payload) {
            guard drop.position == .on, let bookmark = bookmarks[bookmarkID] else { return false }
            switch drop.target {
            case .group(.collections): return bookmark.category != nil
            case .destination(.collection(let id)): return categoryIDs.contains(id) && bookmark.category != id
            case .destination(.tag(let id)): return tagIDs.contains(id) && !bookmark.tags.contains(id)
            case .destination(.project(let id)): return projectLinks[id].map { !$0.contains(bookmarkID) } ?? false
            case .destination(.favorites): return !bookmark.favorite
            case .destination(.unsorted): return bookmark.category != nil
            case .destination(.inbox): return !bookmark.inbox
            case .destination(.readingQueue): return bookmark.done
            default: return false
            }
        }
        guard let source = UUID(uuidString: payload) else { return false }
        switch drop.target {
        case .group(.collections): return drop.position == .on && categoryIDs.contains(source) && categoryParents[source] != nil
        case .destination(.collection(let target)):
            guard categoryIDs.contains(source), source != target else { return false }
            if drop.position == .on { return categoryParents[source] != target && !categoryWouldCycle(source: source, target: target) }
            let parent = categoryParents[target]
            return parent.map { !categoryWouldCycle(source: source, target: $0) } ?? true
        case .destination(.tag(let target)):
            return drop.position != .after && tagIDs.contains(source) && source != target && !tagWouldCycle(source: source, targetParent: tagParents[target])
        default: return false
        }
    }
}

@MainActor final class SidebarOwnedOutline: NSOutlineView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        super.style = .plain
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        super.style = .plain
    }
    // La medida y pintura propias no admiten padding inferido por el contenedor.
    override var style: NSTableView.Style {
        get { .plain }
        set { super.style = .plain }
    }
    weak var owner: SidebarOutlineCoordinator?
    // El contenedor puede escribir .sourceList; la pintura pertenece a SidebarOutlineRow.
    override var selectionHighlightStyle: NSTableView.SelectionHighlightStyle {
        get { .none }
        set { super.selectionHighlightStyle = .none }
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); owner?.windowChanged() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); owner?.backingChanged() }
    override func frameOfCell(atColumn column: Int, row: Int) -> NSRect {
        var rect = super.frameOfCell(atColumn: column, row: row)
        guard column == 0, row >= 0, let item = item(atRow: row) as? SidebarOutlineItem,
              let depth = owner?.snapshot?.depths[item.id] else { return rect }
        let inset = owner?.layouts[item.id]?.indentation ?? CGFloat(depth + 1) * indentationPerLevel
        rect.origin.x = inset
        rect.size.width = max(1, (tableColumns.first?.width ?? rect.width) - inset)
        return rect
    }
    override func frameOfOutlineCell(atRow row: Int) -> NSRect {
        var rect = super.frameOfOutlineCell(atRow: row)
        guard let item = item(atRow: row) as? SidebarOutlineItem,
              let layout = owner?.layouts[item.id], let depth = owner?.snapshot?.depths[item.id],
              layout.indentation < CGFloat(depth + 1) * indentationPerLevel else { return rect }
        rect.origin.x = min(rect.origin.x, max(0, layout.indentation - rect.width))
        return rect
    }
    override func keyDown(with event: NSEvent) {
        if !event.modifierFlags.contains(.command), ["\r", " "].contains(event.charactersIgnoringModifiers ?? ""),
           owner?.activateSelectedAction() == true { return }
        super.keyDown(with: event)
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        let index = row(at: convert(event.locationInWindow, from: nil))
        guard index >= 0, let item = item(atRow: index) as? SidebarOutlineItem else { return nil }
        return owner?.menu(for: item)
    }
}

@MainActor final class SidebarOutlineScrollView: NSScrollView {
    weak var owner: SidebarOutlineCoordinator?
    private let softMask = CAGradientLayer()
    private weak var observedClip: NSClipView?
    deinit { NotificationCenter.default.removeObserver(self) }
    @objc private func clipBoundsChanged(_ notification: Notification) {
        layoutSoftEdges()
    }
    override func layout() { super.layout(); owner?.viewportChanged(); layoutSoftEdges() }
    func setSoftEdges(enabled: Bool) {
        if !enabled || observedClip !== contentView {
            if let observedClip {
                NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip)
                self.observedClip = nil
            }
        }
        if enabled && observedClip == nil {
            contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(clipBoundsChanged(_:)),
                                                   name: NSView.boundsDidChangeNotification, object: contentView)
            observedClip = contentView
        }
        contentView.wantsLayer = true
        contentView.layer?.mask = enabled ? softMask : nil
        layoutSoftEdges()
    }
    private func layoutSoftEdges() {
        guard contentView.layer?.mask === softMask else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        softMask.frame = contentView.bounds
        let extent = min(0.08, DesignSystem.Spacing.md / max(1, contentView.bounds.height))
        softMask.startPoint = CGPoint(x: 0.5, y: 0); softMask.endPoint = CGPoint(x: 0.5, y: 1)
        softMask.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
        softMask.locations = [0, NSNumber(value: extent), NSNumber(value: 1 - extent), 1]
        CATransaction.commit()
    }
}

@MainActor final class SidebarOutlineRow: NSTableRowView {
    var accent: NSColor = .controlAccentColor
    var selectionBase: NSColor = .windowBackgroundColor
    var selectionBackground: NSColor?
    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        // .none evita el tinte del sistema; el hook de fondo siempre se ejecuta.
        if isSelected { drawSelection(in: dirtyRect) }
    }
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 7, yRadius: 7)
        // El relleno opaco del path evita acumulación y conserva el rail fuera del realce.
        (selectionBackground ?? SidebarSelectionPaint.blend(accent, over: selectionBase, alpha: 0.18)).setFill(); path.fill()
        accent.withAlphaComponent(0.30).setStroke(); path.lineWidth = 1; path.stroke()
    }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
    override var focusRingMaskBounds: NSRect { bounds }
}

@MainActor final class SidebarMenuTarget: NSObject {
    weak var owner: SidebarOutlineCoordinator?
    let action: SidebarAction
    init(owner: SidebarOutlineCoordinator, action: SidebarAction) { self.owner = owner; self.action = action }
    @objc func invoke(_ sender: Any?) { owner?.perform?(action) }
}

@MainActor final class SidebarAccessoryButton: NSButton {
    weak var owner: SidebarOutlineCoordinator?
    var accessory: SidebarAccessory?
    private var tracking: NSTrackingArea?
    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { if let accessory { owner?.showTooltip(accessory.title, in: self) } }
    override func mouseExited(with event: NSEvent) { owner?.hideTooltip() }
    @objc func pressed(_ sender: Any?) { if let accessory { owner?.accessory(accessory, view: self) } }
}

@MainActor final class SidebarTooltipView: NSView {
    let text: SidebarAttributedText
    let palette: ThemePalette
    init(title: String, palette: ThemePalette) {
        self.palette = palette
        text = SidebarAttributedText(title, font: .preferredFont(forTextStyle: .caption1), color: NSColor(palette.textPrimary), width: 300)
        super.init(frame: NSRect(x: 0, y: 0, width: ceil(text.size.width) + 16, height: ceil(text.size.height) + 12))
        setAccessibilityElement(true); setAccessibilityRole(.staticText); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor(palette.surface).setFill(); NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        text.draw(in: bounds.insetBy(dx: 8, dy: 6))
    }
}

@MainActor final class SidebarOutlineCell: NSTableCellView, NSTextFieldDelegate {
    private var descriptor: SidebarDescriptor?
    private var rowLayout: SidebarRowLayout?
    private var palette: ThemePalette?
    private weak var owner: SidebarOutlineCoordinator?
    private var accessories: [SidebarAccessoryButton] = []
    private var progress: NSProgressIndicator?
    private var editor: NSTextField?
    private var editingID: UUID?
    private var committing = false
    private let countView = SidebarCounterView()
    private var image: NSImage?
    private var hasThumbnail = false
    private var selectedPaint: SidebarSelectionPaint?
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect); addSubview(countView)
        setAccessibilityElement(true); setAccessibilityRole(.staticText)
        countView.setAccessibilityElement(false)
        countView.clipsToBounds = true
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ row: SidebarDescriptor, layout: SidebarRowLayout, palette: ThemePalette,
                   typography: SidebarNativeTypography, reduceMotion: Bool, owner: SidebarOutlineCoordinator) {
        let previous = descriptor
        let wasSelected = selectedPaint != nil
        let selected = owner.isSelected(row.id)
        selectedPaint = selected ? SidebarSelectionPaint(palette: palette) : nil
        let layout = selectedPaint.map { layout.applyingSelection($0, palette: palette) } ?? layout
        self.owner = owner; descriptor = row; rowLayout = layout; self.palette = palette
        setAccessibilityRole(row.action != nil || row.kind == .group ? .button : .staticText)
        setAccessibilityLabel(row.title); setAccessibilityValue(row.accessibilityValue)
        setAccessibilityHelp(row.accessibilityHint)
        if let data = row.imageData, let thumbnail = NSImage(data: data) { image = thumbnail; hasThumbnail = true }
        else if let symbol = row.symbol {
            hasThumbnail = false
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))?
                .withSymbolConfiguration(.init(paletteColors: [NSColor(row.iconColor ?? palette.textPrimary)]))
        } else { image = nil; hasThumbnail = false }
        image?.isTemplate = false
        countView.frame = layout.counterRect
        if reduceMotion || wasSelected != selected { countView.stop() }
        countView.update(layout.counter, animate: !reduceMotion && wasSelected == selected && previous?.id == row.id && previous?.counter != row.counter)
        while accessories.count > row.accessories.count { accessories.removeLast().removeFromSuperview() }
        while accessories.count < row.accessories.count {
            let button = SidebarAccessoryButton()
            button.bezelStyle = .inline; button.isBordered = false; button.imagePosition = .imageOnly
            button.target = button; button.action = #selector(SidebarAccessoryButton.pressed(_:))
            button.focusRingType = .default
            addSubview(button); accessories.append(button)
        }
        for index in row.accessories.indices {
            let button = accessories[index]; let value = row.accessories[index]
            button.frame = layout.accessoryRects[index]; button.accessory = value; button.owner = owner
            button.image = NSImage(systemSymbolName: value.symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: typography[.accessory].pointSize, weight: .semibold))
            button.contentTintColor = selectedPaint?.foreground(palette.textSecondary, palette: palette) ?? NSColor(palette.textSecondary)
            button.setAccessibilityLabel(value.title); button.setAccessibilityHelp(value.title)
        }
        if row.busy && row.kind == .assistant {
            if progress == nil {
                let view = NSProgressIndicator(); view.style = .spinning; view.controlSize = .mini
                view.setAccessibilityElement(false); addSubview(view); progress = view
            }
            progress?.frame = layout.badgeRect; progress?.startAnimation(nil)
        } else { progress?.stopAnimation(nil); progress?.removeFromSuperview(); progress = nil }
        configureEditor(row, layout: layout, font: typography[.title])
        needsDisplay = true
    }
    private func configureEditor(_ row: SidebarDescriptor, layout: SidebarRowLayout, font: NSFont) {
        guard let id = row.editingUUID, let value = row.editingText else {
            editor?.delegate = nil; editor?.removeFromSuperview(); editor = nil; editingID = nil; return
        }
        if editingID != id {
            editor?.delegate = nil; editor?.removeFromSuperview()
            let field = NSTextField(); field.isBordered = false; field.drawsBackground = false
            field.font = font; field.textColor = palette.map { NSColor($0.textPrimary) }
            field.stringValue = value; field.delegate = self
            field.setAccessibilityLabel("Nombre"); addSubview(field)
            editor = field; editingID = id
            if window != nil { window?.makeFirstResponder(field); field.selectText(nil) }
        }
        editor?.frame = layout.titleRect; editor?.font = font
        if let palette {
            editor?.textColor = selectedPaint?.foreground(palette.textPrimary, palette: palette)
                ?? NSColor(palette.textPrimary)
        }
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, let editor { window?.makeFirstResponder(editor); editor.selectText(nil) }
    }
    func controlTextDidChange(_ notification: Notification) {
        if let id = editingID, let editor { owner?.perform?(.updateRename(id, editor.stringValue)) }
    }
    func controlTextDidEndEditing(_ notification: Notification) { commitEditing() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            editingID = nil; editor?.delegate = nil; owner?.perform?(.cancelRename); return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) { commitEditing(); return true }
        return false
    }
    private func commitEditing() {
        guard !committing, let id = editingID, let editor else { return }
        committing = true; editingID = nil; editor.delegate = nil
        owner?.perform?(.finishRename(id, editor.stringValue)); committing = false
    }
    func disconnect() {
        editor?.delegate = nil; editingID = nil; owner = nil
        progress?.stopAnimation(nil); countView.stop()
        for button in accessories { button.owner = nil; button.target = nil }
    }
    override func mouseDown(with event: NSEvent) {
        if let descriptor, descriptor.kind == .group { owner?.toggle(descriptor.id); return }
        super.mouseDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool {
        guard let descriptor else { return false }
        if let action = descriptor.action { owner?.perform?(action); return true }
        if descriptor.kind == .group { owner?.toggle(descriptor.id); return true }
        if let target = descriptor.target { owner?.setSelection?(target); return true }
        return false
    }
    override func draw(_ dirtyRect: NSRect) {
        guard descriptor != nil, let layout = rowLayout, let palette else { return }
        if editor == nil { layout.title.draw(in: layout.titleRect) }
        layout.status?.draw(in: layout.statusRect)
        if let badge = layout.badge {
            (selectedPaint?.badgeBackground ?? NSColor(palette.accent).withAlphaComponent(0.12)).setFill()
            NSBezierPath(roundedRect: layout.badgeRect, xRadius: layout.badgeRect.height / 2, yRadius: layout.badgeRect.height / 2).fill()
            badge.draw(in: layout.badgeRect.insetBy(dx: 6, dy: 2))
        }
        if let image {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: layout.iconRect, xRadius: hasThumbnail ? 4 : 0, yRadius: hasThumbnail ? 4 : 0).addClip()
            let side = min(image.size.width, image.size.height)
            let source = !hasThumbnail ? NSRect.zero : NSRect(
                x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
            image.draw(in: layout.iconRect, from: source, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

@MainActor final class SidebarCounterView: NSView {
    private var current: SidebarAttributedText?
    private var previous: SidebarAttributedText?
    private var transition: CGFloat = 1
    private var task: Task<Void, Never>?
    override var isFlipped: Bool { true }
    func update(_ value: SidebarAttributedText?, animate: Bool) {
        guard current?.string != value?.string else { current = value; needsDisplay = true; return }
        task?.cancel(); task = nil
        previous = animate ? current : nil; current = value; transition = animate ? 0 : 1
        needsDisplay = true
        guard animate else { return }
        // Cifra anterior y actual reales; transición vertical acotada, sin cambiar alturas.
        task = Task { @MainActor [weak self] in
            for step in 1...12 {
                try? await Task.sleep(for: .milliseconds(25))
                guard !Task.isCancelled, let self else { return }
                self.transition = CGFloat(step) / 12; self.needsDisplay = true
            }
            self?.previous = nil; self?.task = nil
        }
    }
    func stop() { task?.cancel(); task = nil; previous = nil; transition = 1 }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if window == nil { stop() } }
    override func draw(_ dirtyRect: NSRect) {
        if let previous, transition < 1 {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            previous.draw(in: bounds.offsetBy(dx: 0, dy: -bounds.height * transition))
            NSGraphicsContext.restoreGraphicsState()
        }
        current?.draw(in: bounds.offsetBy(dx: 0, dy: bounds.height * (1 - transition)))
    }
}
