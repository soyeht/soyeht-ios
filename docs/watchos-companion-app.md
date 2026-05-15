# watchOS Companion App - soyeht

> Companion app for Apple Watch: instance monitoring, voice commands, and real-time notifications.

---

## User Stories

> Default usage pattern: **glance -> assess -> act (or ignore)**. The Watch does not replace the terminal - it acts as a radar surface that keeps the user informed and allows micro-interventions without pulling the phone out.

### Away from the computer

- **"Hey Siri, are my servers up?"** - quick glance at instance status while walking
- **"Show workspaces on picoclaw-01"** - check whether that deploy left running is still active
- **"How many sessions are open?"** - watch face complication, no app launch needed

### Passive monitoring (notifications)

- *Tap on the wrist:* "deploy.sh finished (exit 0) on picoclaw-01" -> tap "View Output"
- *Tap on the wrist:* "ERROR: out of memory on picoclaw-02" -> tap "Rerun" or "View Output"
- *Tap on the wrist:* "picoclaw-03 went offline" -> immediate signal that investigation is needed
- *Tap on the wrist:* "workspace 'dev' idle for 2h" -> tap "Terminate" to free resources

### Everyday quick commands

- **"Hey Siri, soyeht run git status"** - check whether the repo has pending changes
- **"Hey Siri, soyeht run docker ps"** - inspect running containers
- **"Hey Siri, soyeht deploy staging"** - trigger a deploy from the wrist
- **"Hey Siri, soyeht restart nginx"** - restart an emergency service

### Fast reactions (receive a notification and act immediately)

- Receive an error alert -> **dictate: "tail -20 /var/log/app.log"** -> inspect the latest lines
- Build failed -> **tap "Rerun"** directly from the notification
- Process hung -> **dictate: "kill -9 1234"** or tap the quick command "kill last"
- Slow server -> **dictate: "top -n 1"** -> see a CPU and memory summary

### At the gym / running

- Glance at the wrist, see the complication: "3 instances - all healthy" -> no action needed
- Tap: "CI pipeline finished - all tests passed" -> keep training
- Tap: "CI failed - 3 tests broken" -> know there is work waiting later

### In a meeting (cannot pick up the phone)

- Discreet glance at the wrist: instances healthy? active workspaces?
- Soft tap: deploy finished -> quick mental check, continue the meeting
- Quick tap: run `git pull && npm run build` on the remote workspace

### Overnight (on-call)

- Strong tap: "CRITICAL: database connection lost on picoclaw-01"
- On the Watch: tap "View Output" -> inspect the error
- Dictate: "systemctl restart postgresql" -> fix it without getting out of bed
- Confirm: `capture-pane` shows "postgresql started" -> go back to sleep

### Favorite Quick Commands (configured on iPhone)

```
▶ git status
▶ docker ps
▶ df -h
▶ free -m
▶ tail -5 /var/log/syslog
▶ deploy staging
▶ restart app
```

---

## Overview

Apple Watch does not support a full terminal experience (small display, no keyboard), but it works well as a **companion app** for:

1. **Instance status** - see which instances are active from the wrist
2. **Voice commands** - run predefined or dictated commands
3. **Notifications** - error alerts, completed deploys, finished processes
4. **Complications** - summarized status directly on the watch face

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│                   Apple Watch                   │
│                                                 │
│  ┌──────────────┐  ┌──────────────┐  ┌────────┐ │
│  │ Complications │  │ Voice Cmds   │  │ Alerts │ │
│  └──────┬───────┘  └──────┬───────┘  └───┬────┘ │
│         │                 │               │      │
│         └────────────┬────┴───────────────┘      │
│                      │                            │
│          ┌───────────▼───────────┐               │
│          │     WatchSoyehtAPI    │               │
│          │      (URLSession)     │               │
│          └───────────┬───────────┘               │
└──────────────────────┼───────────────────────────┘
                       │ HTTPS
                       ▼
             ┌─────────────────────┐
             │   soyeht Backend    │
             │     /api/v1/...     │
             └─────────────────────┘
```

The Watch communicates **directly with the backend** over HTTPS. It does not depend on the iPhone being nearby as long as Wi-Fi or cellular is available.

---

## Features

### 1. Instance Dashboard

**Main screen** - compact list of active instances.

```
┌──────────────────────┐
│  soyeht        12:30 │
│                      │
│  ● picoclaw-01       │
│    2 workspaces      │
│                      │
│  ● picoclaw-02       │
│    1 workspace       │
│                      │
│  ○ picoclaw-03       │
│    offline           │
└──────────────────────┘
```

**Endpoints used:**
- `GET /api/v1/mobile/instances` - list instances
- `GET /api/v1/terminals/{container}/workspaces` - count workspaces per instance

**Tap an instance** - show workspaces with status and quick actions.

---

### 2. Voice Commands

Three forms of voice input on watchOS:

#### a) Native dictation (speech-to-text)

watchOS provides `presentTextInputController`, which opens the native dictation keyboard. The user speaks the command and the Watch converts it to text.

```swift
// SwiftUI - watchOS 9+
TextField("Command...", text: $command)
    .onSubmit {
        executeCommand(command)
    }

// Or use dictation directly
func startDictation() {
    // watchOS opens the dictation UI automatically
    // when the user taps the TextField
}
```

**Flow:**
1. User taps "Run Command" on the Watch
2. watchOS opens the dictation UI
3. User says: "git status"
4. Watch sends the command to the backend
5. Watch shows summarized output (first lines)

**Command execution endpoint:**
```
POST /api/v1/terminals/{container}/workspace
-> open/reuse workspace

WS wss://{host}/api/v1/terminals/{container}/pty?session={id}&token={token}
-> send command over WebSocket
-> read response (first N bytes)
-> close connection
```

**Alternative without WebSocket (simpler for v1):**
```
POST /api/v1/terminals/{container}/tmux/send-keys
Body: { "session": "workspace-name", "keys": "git status\n" }

GET /api/v1/terminals/{container}/tmux/capture-pane?session=workspace-name
-> returns pane output (text)
```

> Note: `send-keys` + `capture-pane` is simpler than WebSocket for one-shot commands on Watch. The backend already exposes `capture-pane`.

#### b) Siri / App Shortcuts

Using **App Intents** (iOS 16+ / watchOS 9+), the user can create voice shortcuts:

```swift
struct RunCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Run Soyeht Command"
    static var description = IntentDescription("Execute a command on a soyeht instance")

    @Parameter(title: "Command")
    var command: String

    @Parameter(title: "Instance")
    var instance: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command) on \(\.$instance)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let api = WatchSoyehtAPI.shared
        let output = try await api.executeCommand(
            command: command,
            instance: instance ?? api.defaultInstance
        )
        return .result(dialog: "Output: \(output.prefix(200))")
    }
}

struct SoyehtShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunCommandIntent(),
            phrases: [
                "Run \(\.$command) on soyeht",
                "Execute \(\.$command) on \(\.$instance)",
                "Soyeht run \(\.$command)"
            ],
            shortTitle: "Run Command",
            systemImageName: "terminal"
        )
    }
}
```

**Usage examples:**
- "Hey Siri, soyeht run git status"
- "Hey Siri, execute deploy on picoclaw-01"

#### c) Predefined commands (quick actions)

List of favorite commands configured on iPhone, synced through Watch Connectivity or the API.

```
┌──────────────────────┐
│  Quick Commands      │
│                      │
│  ▶ git status        │
│  ▶ docker ps         │
│  ▶ tail -f logs      │
│  ▶ deploy staging    │
│                      │
│  + Add Command       │
│                      │
│  🎤 Dictate...       │
└──────────────────────┘
```

**When a command is tapped:**
1. Send it through `send-keys` to the active workspace
2. Wait 1-2s
3. Call `capture-pane` and show summarized output
4. Play success/error haptic feedback

---

### 3. Notifications

**Push notifications** for important events via APNs.

| Event | Example |
|---|---|
| Process finished | "deploy.sh finished (exit 0)" |
| Error detected | "ERROR in build.log" |
| Instance offline | "picoclaw-01 went offline" |
| Idle workspace | "workspace 'dev' idle for 30min" |

**Implementation:**
- Backend sends pushes through APNs when it detects an event
- Watch receives the notification and shows inline actions
- Actions: "View Output", "Rerun", "Ignore"

```swift
// Notification category with actions
let viewAction = UNNotificationAction(
    identifier: "VIEW_OUTPUT",
    title: "View Output"
)
let rerunAction = UNNotificationAction(
    identifier: "RERUN",
    title: "Rerun"
)
let category = UNNotificationCategory(
    identifier: "COMMAND_FINISHED",
    actions: [viewAction, rerunAction],
    intentIdentifiers: []
)
```

**Backend requirement:**
- Endpoint to register the APNs device token: `POST /api/v1/mobile/push-token`
- Push service that monitors events and sends notifications

---

### 4. Complications (watch face)

Show summarized info directly on the watch face without opening the app.

| Type | Content |
|---|---|
| Circular | Number of active instances (for example, "3") |
| Rectangular | "picoclaw-01: 2 ws" |
| Inline | "soyeht: 3 active" |

```swift
struct SoyehtComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "SoyehtStatus",
            provider: StatusProvider()
        ) { entry in
            VStack {
                Text("\(entry.activeCount)")
                    .font(.title)
                Text("instances")
                    .font(.caption2)
            }
        }
        .configurationDisplayName("Soyeht Status")
        .supportedFamilies([
            .accessoryCircular,
            .accessoryRectangular,
            .accessoryInline
        ])
    }
}
```

**Update model:** timeline refresh every 15 minutes through `TimelineProvider`, or push-triggered via `WidgetCenter.shared.reloadAllTimelines()`.

---

## Technical Stack

| Component | Technology |
|---|---|
| UI | SwiftUI (watchOS 9+) |
| Networking | URLSession (direct backend requests) |
| Auth | Shared token via Keychain (App Group) |
| Voice | Native dictation + App Intents (Siri) |
| Notifications | APNs + UNUserNotificationCenter |
| Complications | WidgetKit (watchOS 9+) |
| iPhone<->Watch sync | Watch Connectivity (config/favorites) |
| Local persistence | SwiftData or UserDefaults |

---

## Code Sharing with iOS

```
iSoyehtTerm/
├── Shared/                          # Shared iOS + watchOS code
│   ├── SoyehtAPIClient.swift        # Move from iOSTerminal/ to here
│   ├── Models/
│   │   ├── SoyehtWorkspace.swift
│   │   ├── TmuxWindow.swift
│   │   └── Instance.swift
│   └── SessionStore.swift           # Keychain + token management
│
├── TerminalApp/
│   ├── iOSTerminal/                 # iOS app (full terminal)
│   └── SoyehtMac/                   # macOS app (full terminal)
│
├── WatchApp/
│   ├── WatchApp.swift               # Entry point
│   ├── Views/
│   │   ├── DashboardView.swift      # List of instances
│   │   ├── WorkspaceListView.swift  # Workspaces per instance
│   │   ├── QuickCommandsView.swift  # Predefined commands
│   │   └── CommandOutputView.swift  # Summarized output
│   ├── Intents/
│   │   ├── RunCommandIntent.swift   # Siri "run X on soyeht"
│   │   └── SoyehtShortcuts.swift    # App Shortcuts provider
│   ├── Complications/
│   │   └── StatusWidget.swift       # Watch face complication
│   └── WatchApp.xcodeproj
│
└── Package.swift                    # SwiftTerm (iOS/macOS only)
```

**What can be reused from iOS:**
- `SoyehtAPIClient` - all REST calls (move to `Shared/`)
- `SessionStore` - token/keychain management
- Models - `SoyehtWorkspace`, `TmuxWindow`, `Instance`

**What is Watch-only:**
- UI (compact SwiftUI for watch)
- App Intents / Siri integration
- Complications
- `send-keys` + `capture-pane` logic (one-shot commands)

---

## Implementation Phases

### Phase 1 - MVP (basic companion app)
- [ ] Create the WatchApp target in Xcode
- [ ] Extract `SoyehtAPIClient` and models to `Shared/`
- [ ] Dashboard: list instances and workspaces
- [ ] Share token through a Keychain App Group
- [ ] Simple complication (instance count)

### Phase 2 - Voice Commands
- [ ] Quick Commands (predefined list)
- [ ] Voice dictation -> `send-keys` + `capture-pane`
- [ ] Show summarized output on Watch
- [ ] Haptic feedback

### Phase 3 - Siri and Notifications
- [ ] App Intents + App Shortcuts
- [ ] Push notifications (requires backend APNs service)
- [ ] Inline notification actions
- [ ] Background App Refresh for complications

### Phase 4 - Polish
- [ ] Watch Connectivity (sync favorites with iPhone)
- [ ] Recent command history
- [ ] Theme/appearance consistency with iOS
- [ ] Advanced complications (last command, detailed status)

---

## New Backend Endpoints Needed

| Endpoint | Needed for | Phase |
|---|---|---|
| `POST /api/v1/terminals/{container}/tmux/send-keys` | Send command without WebSocket | 2 |
| `POST /api/v1/mobile/push-token` | Register device for push | 3 |
| Push notification service (APNs) | Send alerts to Watch | 3 |

> All other endpoints already exist and will be reused from iOS.
