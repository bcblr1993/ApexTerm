import XCTest
import AppKit
import SwiftUI
@testable import ApexCore
@testable import ApexSSH
@testable import ApexTerminal

final class TerminalFindAndURLTests: XCTestCase {
    
    @MainActor
    func testViewUpdatesPreserveFileControlFocusAndPaneActivationRestoresTerminalFocus() throws {
        _ = NSApplication.shared
        let buffer = TerminalRingBuffer()
        buffer.appendStream("demo output\n")
        let host = NSHostingView(rootView: TerminalRepresentable(ringBuffer: buffer, isFocused: true, onInput: { _ in }))
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        host.frame = NSRect(x: 0, y: 50, width: 640, height: 350)
        let pathField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        container.addSubview(host)
        container.addSubview(pathField)
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        func findTerminal(_ view: NSView) -> NativeTerminalView? {
            if let terminal = view as? NativeTerminalView { return terminal }
            for child in view.subviews { if let terminal = findTerminal(child) { return terminal } }
            return nil
        }
        let terminal = try XCTUnwrap(findTerminal(host))
        XCTAssertTrue(window.makeFirstResponder(pathField))
        XCTAssertTrue(window.firstResponder === pathField || pathField.currentEditor() === window.firstResponder)
        host.rootView = TerminalRepresentable(ringBuffer: buffer, isFocused: true, onInput: { _ in })
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(window.firstResponder === pathField || pathField.currentEditor() === window.firstResponder, "Rendering updates must leave the path control editing; field-editor instance identity may change")

        host.rootView = TerminalRepresentable(ringBuffer: buffer, isFocused: false, onInput: { _ in })
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        host.rootView = TerminalRepresentable(ringBuffer: buffer, isFocused: true, onInput: { _ in })
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(window.firstResponder === terminal, "Selecting a terminal pane must focus that pane")
    }

    @MainActor
    func testTerminalMountedInVisibleWindowGetsFocusWithoutStealingFieldEditing() {
        _ = NSApplication.shared
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        defer { window.orderOut(nil) }
        let terminal = NativeTerminalScrollView(frame: container.bounds)
        terminal.requestsInitialFocus = true
        container.addSubview(terminal)
        let focusDeadline = Date(timeIntervalSinceNow: 2)
        while window.firstResponder !== terminal.terminalView && Date() < focusDeadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        XCTAssertTrue(window.firstResponder === terminal.terminalView)

        terminal.removeFromSuperview()
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 30))
        container.addSubview(field)
        window.makeFirstResponder(field)
        container.addSubview(terminal)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        XCTAssertTrue(window.firstResponder === field || field.currentEditor() === window.firstResponder)
    }

    @MainActor
    func testControlCommandFUsesWindowFullScreenInsteadOfTerminalInput() throws {
        final class FullScreenWindow: NSWindow {
            var toggleCount = 0
            override func toggleFullScreen(_ sender: Any?) { toggleCount += 1 }
        }
        let window = FullScreenWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        let terminal = NativeTerminalView()
        window.contentView = terminal
        var inputs: [Data] = []
        terminal.onInput = { inputs.append($0) }
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3))
        terminal.keyDown(with: event)
        XCTAssertEqual(window.toggleCount, 1)
        XCTAssertTrue(inputs.isEmpty)
    }

    // MARK: - 1. Terminal Find Tests
    
    @MainActor
    func testTerminalFindExactAndCaseInsensitive() {
        let view = NativeTerminalView()
        let sample = "Error: connection timeout on port 8080.\nRe-trying ERROR handling for 8080.\nSuccess."
        view.textStorage?.setAttributedString(NSAttributedString(string: sample))
        
        // Search "error" (case-insensitive) -> should match 2 occurrences
        let count = view.performFind(query: "error")
        XCTAssertEqual(count, 2)
        XCTAssertEqual(view.currentMatches.count, 2)
        XCTAssertEqual(view.currentMatchIndex, 0)
        
        // First match is at location 0 ("Error")
        XCTAssertEqual(view.currentMatches[0].location, 0)
        XCTAssertEqual(view.currentMatches[0].length, 5)
        
        // Second match is at location 50 ("ERROR")
        XCTAssertEqual(view.currentMatches[1].length, 5)
        
        // Cycle Next -> index becomes 1
        let nextMatch = view.findNext()
        XCTAssertNotNil(nextMatch)
        XCTAssertEqual(view.currentMatchIndex, 1)
        
        // Cycle Next again -> wraps around to 0
        let wrapMatch = view.findNext()
        XCTAssertNotNil(wrapMatch)
        XCTAssertEqual(view.currentMatchIndex, 0)
        
        // Cycle Previous from 0 -> wraps back to 1
        let prevMatch = view.findPrevious()
        XCTAssertNotNil(prevMatch)
        XCTAssertEqual(view.currentMatchIndex, 1)
        
        // Clear search
        view.clearFind()
        XCTAssertEqual(view.currentMatches.count, 0)
        XCTAssertEqual(view.currentMatchIndex, -1)
    }
    
    @MainActor
    func testTerminalFindNonExistentQuery() {
        let view = NativeTerminalView()
        view.textStorage?.setAttributedString(NSAttributedString(string: "All systems operational"))
        
        let count = view.performFind(query: "fatal_crash")
        XCTAssertEqual(count, 0)
        XCTAssertEqual(view.currentMatches.count, 0)
        XCTAssertEqual(view.currentMatchIndex, -1)
        XCTAssertNil(view.findNext())
        XCTAssertNil(view.findPrevious())
    }
    
    // MARK: - 2. URL Detection Tests
    
    func testURLDetectionVariousFormats() {
        let logLine = "Listening on http://localhost:3000 and https://api.apexterm.com/v1/metrics (see http://192.0.2.10:8080/dashboard?token=xyz)."
        let detected = NativeTerminalView.detectURLs(in: logLine)
        
        XCTAssertEqual(detected.count, 3)
        
        // First URL: http://localhost:3000
        XCTAssertEqual(detected[0].url.absoluteString, "http://localhost:3000")
        
        // Second URL: https://api.apexterm.com/v1/metrics
        XCTAssertEqual(detected[1].url.absoluteString, "https://api.apexterm.com/v1/metrics")
        
        // Third URL: should strip trailing parenthesis and period from http://192.0.2.10:8080/dashboard?token=xyz
        XCTAssertEqual(detected[2].url.absoluteString, "http://192.0.2.10:8080/dashboard?token=xyz")
    }
    
    @MainActor
    func testGetSelectedURL() {
        let view = NativeTerminalView()
        let sample = "Visit https://www.aethernative.com for live releases"
        view.textStorage?.setAttributedString(NSAttributedString(string: sample))
        
        // Select "https://www.aethernative.com" (loc: 6, len: 28)
        view.setSelectedRange(NSRange(location: 6, length: 28))
        let url = view.getSelectedURL()
        XCTAssertNotNil(url)
        XCTAssertEqual(url?.absoluteString, "https://www.aethernative.com")
        
        // Select non-URL text
        view.setSelectedRange(NSRange(location: 0, length: 5))
        XCTAssertNil(view.getSelectedURL())
    }
    
    // MARK: - 3. Top 5 Processes Metric Parsing
    
    func testTopProcessesParsingLinux() {
        let mockOutput = """
        Linux 6.6.0
        ---UPTIME---
        123456
        ---LOAD---
        0.42 0.55 0.60
        ---CPU---
        12.5 4
        ---MEM---
        16000000 8000000 2000000
        ---NET---
        1000000 2000000
        ---DISK---
        100000000 40000000
        ---TOP---
          PID USER      %CPU %MEM COMMAND
         1234 root      45.2  3.1 /usr/bin/dockerd
         5678 www-data  12.0  8.5 nginx: worker process
         9101 ubuntu     5.4  1.2 python3 app.py
         1122 redis      1.1  0.5 redis-server
         3344 node       0.8  4.0 node server.js
        """
        
        let monitor = AgentlessMonitor()
        var prevCpu: AgentlessMonitor.CpuTickState? = nil
        var prevNet: AgentlessMonitor.NetTickState? = nil
        let snapshot = monitor.parseLinuxOutput(mockOutput, prevCpu: &prevCpu, prevNet: &prevNet)
        
        XCTAssertEqual(snapshot.topProcesses.count, 5)
        XCTAssertEqual(snapshot.topProcesses[0].pid, 1234)
        XCTAssertEqual(snapshot.topProcesses[0].user, "root")
        XCTAssertEqual(snapshot.topProcesses[0].cpuPercent, 45.2)
        XCTAssertEqual(snapshot.topProcesses[0].memPercent, 3.1)
        XCTAssertEqual(snapshot.topProcesses[0].command, "/usr/bin/dockerd")
        
        XCTAssertEqual(snapshot.topProcesses[1].pid, 5678)
        XCTAssertEqual(snapshot.topProcesses[1].user, "www-data")
        XCTAssertEqual(snapshot.topProcesses[1].command, "nginx: worker process")
    }
}
