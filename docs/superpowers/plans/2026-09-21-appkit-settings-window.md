# AppKit Settings Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ensure Kacha always presents one reusable settings window when a new app process launches, independently of the menu bar icon’s visibility.

**Architecture:** Replace the SwiftUI `Settings` scene and its unreliable AppKit selector bridge with an AppKit-owned `NSWindowController`. `AppDelegate` owns that controller and uses it for cold launch, reopen requests when the menu bar icon is hidden, and the menu’s Settings command. The window’s content remains the existing SwiftUI `SettingsView`, hosted with `NSHostingView`.

**Tech Stack:** Swift 6, SwiftUI, AppKit, XCTest, macOS 26.0.

**Spec:** `docs/superpowers/specs/2026-09-18-kacha-settings-design.md`

## Global Constraints

- Target platform is macOS 26.0 as declared in `Package.swift`.
- Keep the project dependency-free; use AppKit and SwiftUI only.
- Preserve all existing settings controls and their persistence behavior.
- Keep Kacha as an LSUIElement menu-bar app.
- A cold launch opens the settings window regardless of `showMenuBarIcon`.
- An existing Kacha process is reused by macOS; when reopened with the menu bar icon hidden, bring the existing settings window to the front.
- Use the project’s development-certificate installation flow (`make install`) for local app validation.

---

## File Structure

- Create `Sources/Kacha/SettingsWindowController.swift` — creates and owns the single reusable AppKit settings window whose content is `SettingsView`.
- Modify `Sources/Kacha/KachaApp.swift` — removes the SwiftUI `Settings` scene and `SettingsLink`; delegates all settings-open requests to the AppKit controller.
- Create `Tests/KachaTests/SettingsWindowControllerTests.swift` — verifies the controller’s single-window lifecycle without relying on the deprecated SwiftUI settings selector.
- Modify `Tests/KachaTests/SettingsLaunchPolicyTests.swift` — removes the obsolete run-loop scheduling assertion and retains only cold-launch/reopen policy behavior.
- Modify `Tests/KachaTests/SettingsLayoutTests.swift` — retains compact-size checks; the AppKit controller will use the same `SettingsLayout` constants.

### Task 1: Establish a testable settings-window lifecycle coordinator

**Files:**
- Create: `Sources/Kacha/SettingsWindowController.swift`
- Create: `Tests/KachaTests/SettingsWindowControllerTests.swift`

**Interfaces:**
- Produces: `@MainActor final class SettingsWindowController`
- Produces: `func show()` — lazily creates a window once, then makes that same window key and frontmost.
- Produces: `var window: NSWindow? { get }` — exposed internally for lifecycle assertions.
- Consumes: `SettingsView(appDelegate:)` and `SettingsLayout.minimumWidth` / `SettingsLayout.minimumHeight`.

- [ ] **Step 1: Write the failing lifecycle test**

```swift
import AppKit
import XCTest
@testable import kacha

@MainActor
final class SettingsWindowControllerTests: XCTestCase {
    func test_showCreatesOneReusableSettingsWindow() {
        let appDelegate = AppDelegate()
        let controller = SettingsWindowController(appDelegate: appDelegate)

        controller.show()
        let firstWindow = try! XCTUnwrap(controller.window)
        controller.show()

        XCTAssertTrue(controller.window === firstWindow)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter SettingsWindowControllerTests`

Expected: compilation failure because `SettingsWindowController` does not exist.

- [ ] **Step 3: Implement the smallest AppKit controller**

```swift
import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let appDelegate: AppDelegate
    private(set) var window: NSWindow?

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(appDelegate: appDelegate)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: SettingsLayout.minimumWidth,
                height: SettingsLayout.minimumHeight
            ),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "设置"
        window.contentView = NSHostingView(rootView: view)
        window.minSize = NSSize(
            width: SettingsLayout.minimumWidth,
            height: SettingsLayout.minimumHeight
        )
        window.isReleasedWhenClosed = false
        return window
    }
}
```

- [ ] **Step 4: Run the lifecycle test to verify it passes**

Run: `swift test --filter SettingsWindowControllerTests`

Expected: PASS with 1 test and 0 failures.

- [ ] **Step 5: Commit the controller and its test**

```bash
git add Sources/Kacha/SettingsWindowController.swift Tests/KachaTests/SettingsWindowControllerTests.swift
git commit -m "feat: add reusable AppKit settings window"
```

### Task 2: Route all settings requests through the AppKit controller

**Files:**
- Modify: `Sources/Kacha/KachaApp.swift:15-47,62-85,134-136`
- Modify: `Tests/KachaTests/SettingsLaunchPolicyTests.swift`

**Interfaces:**
- Consumes: `SettingsWindowController(appDelegate:)` and `SettingsWindowController.show()` from Task 1.
- Produces: `AppDelegate.openSettings()` callable by both lifecycle methods and the SwiftUI menu button.
- Removes: SwiftUI `Settings { ... }` scene, `SettingsLink`, `showSettingsWindow:` selector, and `scheduleSettingsAfterColdLaunch`.

- [ ] **Step 1: Rewrite the failing policy test around direct AppKit presentation**

Replace the run-loop scheduling test with this policy-only test so the suite no longer requires deferred selector behavior:

```swift
func test_coldLaunchUsesDirectSettingsPresentation() {
    XCTAssertTrue(SettingsLaunchPolicy.shouldOpenSettingsOnLaunch)
}
```

Keep these existing assertions unchanged:

```swift
XCTAssertTrue(SettingsLaunchPolicy.shouldOpenSettingsOnReopen(showMenuBarIcon: false))
XCTAssertFalse(SettingsLaunchPolicy.shouldOpenSettingsOnReopen(showMenuBarIcon: true))
```

- [ ] **Step 2: Run the policy test to verify it fails against the old bridge API**

Run: `swift test --filter SettingsLaunchPolicyTests`

Expected: compilation failure because the old test still calls `scheduleSettingsAfterColdLaunch`, which will be removed by this task.

- [ ] **Step 3: Replace the scene and selector bridge**

Make the following focused changes in `KachaApp.swift`:

```swift
struct KachaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true

    var body: some Scene {
        MenuBarExtra("咔嚓", systemImage: "camera.viewfinder", isInserted: $showMenuBarIcon) {
            MenuContent(appDelegate: appDelegate)
        }
    }
}
```

Replace `SettingsLink` in `MenuContent` with:

```swift
Button("设置…") {
    appDelegate.openSettings()
}
```

In `AppDelegate`, add one stored controller and initialize it after `super.init()`:

```swift
private lazy var settingsWindowController = SettingsWindowController(appDelegate: self)
```

Replace cold-launch handling with:

```swift
if SettingsLaunchPolicy.shouldOpenSettingsOnLaunch {
    openSettings()
}
```

Implement a non-private entry point that calls the AppKit controller:

```swift
func openSettings() {
    settingsWindowController.show()
}
```

Retain the existing hidden-menu-bar reopen guard, but call this `openSettings()` method. Delete the selector-based `private func openSettings()` implementation and delete `scheduleSettingsAfterColdLaunch` from `SettingsLaunchPolicy`.

- [ ] **Step 4: Run the policy and controller tests to verify they pass**

Run: `swift test --filter 'Settings(LaunchPolicy|WindowController)Tests'`

Expected: PASS with all selected settings lifecycle tests and 0 failures.

- [ ] **Step 5: Commit the lifecycle routing change**

```bash
git add Sources/Kacha/KachaApp.swift Tests/KachaTests/SettingsLaunchPolicyTests.swift
git commit -m "fix: present settings window through AppKit"
```

### Task 3: Validate compact window sizing and app behavior

**Files:**
- Modify: `Tests/KachaTests/SettingsLayoutTests.swift` only if the Task 1 controller requires an additional size assertion.
- Modify: no production files unless validation exposes a direct mismatch between `SettingsLayout` and `SettingsWindowController`.

**Interfaces:**
- Consumes: `SettingsLayout.minimumWidth == 480`, `SettingsLayout.minimumHeight == 280`.
- Consumes: `SettingsWindowController.window?.minSize` from Task 1.

- [ ] **Step 1: Add the failing controller-size assertion**

Append to `SettingsWindowControllerTests`:

```swift
func test_createdWindowUsesSettingsLayoutMinimumSize() {
    let controller = SettingsWindowController(appDelegate: AppDelegate())

    controller.show()
    let window = try! XCTUnwrap(controller.window)

    XCTAssertEqual(window.minSize.width, SettingsLayout.minimumWidth)
    XCTAssertEqual(window.minSize.height, SettingsLayout.minimumHeight)
}
```

- [ ] **Step 2: Run the test to verify it fails if Task 1 omitted `window.minSize`**

Run: `swift test --filter SettingsWindowControllerTests/test_createdWindowUsesSettingsLayoutMinimumSize`

Expected: FAIL only when Task 1 has not set `window.minSize`; otherwise it already passes and documents the completed compact-size contract.

- [ ] **Step 3: Set the minimum size if the test exposed a gap**

Ensure `makeWindow()` contains exactly this sizing constraint:

```swift
window.minSize = NSSize(
    width: SettingsLayout.minimumWidth,
    height: SettingsLayout.minimumHeight
)
```

- [ ] **Step 4: Run the full automated verification suite**

Run: `swift test && swift build -c release && git diff --check`

Expected: all tests pass, release build succeeds, and no whitespace errors are emitted.

- [ ] **Step 5: Install and manually smoke-test the signed app**

Run: `pkill -x kacha 2>/dev/null || true && make install`

Manual checks:

1. From a stopped state, open `/Applications/Kacha.app`; a settings window appears.
2. Close the settings window, hide the menu-bar icon, and use Finder or `open -a Kacha`; the existing process opens and activates settings instead of starting another instance.
3. Open the menu with the icon visible and choose “设置…”; the same settings window is shown.
4. Confirm the compact window is at least 480 × 280 pt and uses the native SwiftUI `TabView`.

- [ ] **Step 6: Commit final test adjustment if Task 3 changed files**

```bash
git add Tests/KachaTests/SettingsWindowControllerTests.swift Tests/KachaTests/SettingsLayoutTests.swift
git commit -m "test: cover settings window sizing"
```

## Self-Review

- **Spec coverage:** The plan preserves the existing three settings controls, compact `SettingsLayout` contract, tray menu entry, hidden-tray reopen behavior, and first-process settings presentation. It deliberately replaces the spec’s obsolete selector/SwitchUI Settings-scene bridge with an AppKit window controller, because the verified runtime behavior showed that bridge does not reliably create an initial settings window.
- **Placeholder scan:** No TODO/TBD markers, unnamed implementation steps, or unspecified test behavior remain.
- **Type consistency:** `SettingsWindowController.show()`, `SettingsWindowController.window`, `AppDelegate.openSettings()`, and `SettingsLayout.minimumWidth`/`minimumHeight` are defined consistently across all tasks.
