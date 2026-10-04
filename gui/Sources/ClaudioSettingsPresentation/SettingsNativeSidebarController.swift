import AppKit
import ClaudioGUIComponents
import ClaudioGUICore
import ClaudioLocalization
import SwiftUI

@MainActor
package final class SettingsNativeSidebarController: NSViewController, NSTableViewDataSource,
    NSTableViewDelegate
{
    package let table = SettingsSidebarTableView()
    private let session: SettingsPresentationSession
    private let notice = NSTextField(wrappingLabelWithString: "")
    private var rows: [SettingsDestination?] = []
    private var synchronizingSelection = false
    private var language: ClaudioAppLanguage?
    package var isNavigationEnabled = true

    package init(session: SettingsPresentationSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    package override func loadView() {
        view = NSView()
        let brand = NSHostingView(rootView: ClaudioOrbitWordmark(height: 19))
        brand.setAccessibilityElement(false)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.style = .sourceList
        table.allowsMultipleSelection = false
        table.allowsEmptySelection = false
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 32
        table.intercellSpacing = .zero
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("destination"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.delegate = self
        table.dataSource = self
        table.setAccessibilityIdentifier("settings.sidebar")
        table.onMove = { [weak self] direction in self?.move(direction) }
        table.onReselect = { [weak self] in self?.navigateToSelection() }
        scroll.documentView = table
        notice.font = .systemFont(ofSize: 11)
        notice.textColor = .secondaryLabelColor
        notice.setAccessibilityIdentifier("settings.sidebar.local-first")
        for child in [brand, scroll, notice] {
            child.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(child)
        }
        NSLayoutConstraint.activate([
            brand.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            brand.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 26),
            brand.heightAnchor.constraint(equalToConstant: 19),
            scroll.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: notice.topAnchor, constant: -18),
            notice.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            notice.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            notice.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
        ])
        update(session.state)
    }

    package func update(_ state: SettingsPresentationState) {
        guard isViewLoaded else { return }
        let previousSynchronization = synchronizingSelection
        synchronizingSelection = true
        defer { synchronizingSelection = previousSynchronization }
        isNavigationEnabled = state.chrome.navigationEnabled
        table.isEnabled = isNavigationEnabled
        let sections = settingsSidebarSections(
            availableDestinations: session.dependencies.preferences.availableSettingsDestinations)
        let nextRows: [SettingsDestination?] = sections.enumerated().flatMap { index, section in
            (index == 0 ? [] : [nil]) + section.destinations.map(Optional.some)
        }
        if rows != nextRows || language != state.language {
            rows = nextRows
            language = state.language
            table.reloadData()
        }
        notice.stringValue = ClaudioL10n(language: state.language).text(.settingsNativeLocalNotice)
        table.setAccessibilityLabel(
            ClaudioL10n(language: state.language).text(.settingsWindowTitle))
        select(state.chrome.destination)
    }

    package func select(_ destination: SettingsDestination) {
        guard let index = rows.firstIndex(of: destination), table.selectedRow != index else {
            return
        }
        let previousSynchronization = synchronizingSelection
        synchronizingSelection = true
        defer { synchronizingSelection = previousSynchronization }
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        table.scrollRowToVisible(index)
    }

    package func focusSelection() {
        guard let window = view.window, window.isKeyWindow, window.attachedSheet == nil else {
            return
        }
        window.makeFirstResponder(table)
    }

    package func frame(for destination: SettingsDestination) -> NSRect? {
        rows.firstIndex(of: destination).map(table.rect(ofRow:))
    }

    package func numberOfRows(in _: NSTableView) -> Int { rows.count }
    package func tableView(_: NSTableView, heightOfRow row: Int) -> CGFloat {
        rows[row] == nil ? 16 : 32
    }
    package func tableView(_: NSTableView, isGroupRow row: Int) -> Bool { rows[row] == nil }
    package func tableView(_: NSTableView, shouldSelectRow row: Int) -> Bool {
        rows.indices.contains(row) && rows[row] != nil
            && (synchronizingSelection || isNavigationEnabled)
    }

    package func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = NSTableRowView()
        if let destination = rows[row] {
            view.setAccessibilityIdentifier("settings.sidebar.\(destination.rawValue)")
            view.setAccessibilityLabel(destination.localizedName(language: language ?? .english))
        } else {
            view.setAccessibilityElement(false)
        }
        return view
    }

    package func tableView(_: NSTableView, viewFor _: NSTableColumn?, row: Int) -> NSView? {
        guard let destination = rows[row] else { return NSView() }
        let cell = NSTableCellView()
        let label = NSTextField(
            labelWithString: destination.localizedName(language: language ?? .english))
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        cell.textField = label
        let icon = NSHostingView(rootView: SettingsSidebarIcon(destination: destination))
        icon.setAccessibilityElement(false)
        for child in [icon, label] {
            child.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(child)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    package func tableViewSelectionDidChange(_: Notification) {
        navigateToSelection()
    }

    private func navigateToSelection() {
        guard !synchronizingSelection, isNavigationEnabled,
            rows.indices.contains(table.selectedRow),
            let destination = rows[table.selectedRow]
        else { return }
        _ = session.send(.selectSidebar(destination))
        focusSelection()
    }

    private func move(_ direction: SettingsSidebarMoveDirection) {
        guard isNavigationEnabled else { return }
        let current = session.state.chrome.destination
        let destination = settingsSidebarDestination(
            moving: direction, from: current,
            availableDestinations: rows.compactMap { $0 })
        guard destination != current, let row = rows.firstIndex(of: destination) else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
}

@MainActor
package final class SettingsSidebarTableView: NSTableView {
    package var onMove: ((SettingsSidebarMoveDirection) -> Void)?
    package var onReselect: (() -> Void)?
    package func reselectRow(_ row: Int) {
        guard isEnabled, row >= 0, row == selectedRow else { return }
        onReselect?()
    }
    package override var needsPanelToBecomeKey: Bool { true }
    package override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        let previous = selectedRow
        let clicked = row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        if clicked == previous { reselectRow(clicked) }
        window?.makeFirstResponder(self)
    }
    package override func keyDown(with event: NSEvent) {
        if event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.keyCode == 125 { onMove?(.next); return }
            if event.keyCode == 126 { onMove?(.previous); return }
        }
        super.keyDown(with: event)
    }
}
