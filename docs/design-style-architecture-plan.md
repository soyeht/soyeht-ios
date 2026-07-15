# Design Style Architecture Plan (Neumorphism first, Neobrutalism prepared)

Status: PLAN ONLY — nothing implemented yet. Written for review before any code lands.

## 1. Goal

The app should support multiple **design styles** (visual skins) on top of the
**color theme** system that already exists and works today:

- Style #1 to implement now: **Neumorphism** (the two "Mac Terminal · Neo"
  screens in Pencil).
- Style #2 to prepare for, but NOT implement: **Neobrutalism** (the
  "Mac Terminal · V4 Bento + Claw Drawer" screen).
- More styles must be addable later without re-architecting.
- The existing Settings → Color Theme picker must keep working inside every
  style: style and color are **orthogonal axes**.

### Source designs (Pencil)

File: `~/Documents/SwiftProjects/soyeht-ios-screens/unica.pen`

| Node | Name | Style | Pencil theme axis |
|---|---|---|---|
| `A3wSu` | Mac Terminal · Neo V1 Cloud · Flat | Neumorphism | `neo: classic` (light) |
| `t8cLj` | Mac Terminal · Neo V2 Midnight · Flat | Neumorphism | `neo: midnight` (dark) |
| `xLhx2` | Mac Terminal · V4 Bento + Claw Drawer | Neobrutalism | `mode: light/dark` |

Key insight from the .pen file: the design **already models the split we
need**. The two neumorphic screens are structurally identical; only the values
of the `neo` theme axis differ (`classic` / `midnight` / `cream`). Structure +
shadow treatment = *style*; the axis values = *color theme*. The app
architecture should mirror that exactly.

## 2. Current state (verified in code)

- The only theming axis today is the terminal color theme:
  `TerminalColorTheme` (struct, `Packages/SoyehtCore/Sources/SoyehtCore/Terminal/TerminalColorTheme.swift`),
  selected in `TerminalApp/Soyeht/Settings/Appearance/ColorThemeView.swift`,
  persisted by `TerminalPreferences.shared.colorTheme`
  (`UserDefaults` key `soyeht.terminal.colorTheme`,
  `Packages/SoyehtCore/Sources/SoyehtCore/Preferences/TerminalPreferences.swift`).
- Every app-level semantic color is **derived** from the terminal theme by
  `SoyehtAppPalette` (`Packages/SoyehtCore/Sources/SoyehtCore/Theme/SoyehtAppPalette.swift`,
  ~29 roles, WCAG-contrast aware).
- Views consume colors through **static facades**, not SwiftUI Environment:
  - iOS: `SoyehtTheme` (`TerminalApp/Soyeht/SoyehtTheme.swift`, ~947 call sites)
  - macOS: `MacTheme` (`TerminalApp/SoyehtMac/MacTheme.swift`) + component
    enums `EditorPaneDesign`, `GitPaneDesign`, `MacClawStoreTheme`, `SidebarTokens`
  - shared: `BrandColors` (`Packages/SoyehtCore/Sources/SoyehtCore/Theme/BrandColors.swift`)
- Change propagation is `NotificationCenter` (`.soyehtColorThemeChanged`),
  views redraw and the static facades recompute from `TerminalColorTheme.active`.
- Typography is centralized (`SoyehtCore/Theme/Typography.swift`).
- **There is no shape/shadow/border/spacing token system.** Radii, paddings
  and shadows are inline literals per view. This is the missing dimension a
  design style needs.

Implications:

1. A "design style" is a genuinely new axis; nothing collides with color.
2. The static-facade + notification pattern already scales to ~1000 call
   sites; the style system should reuse the same pattern rather than
   introduce a second, competing mechanism (Environment objects).
3. The real work is not colors — it is introducing **surface/elevation
   tokens** and a small rendering layer, then migrating chrome views to it.

## 3. Core model: two orthogonal axes

```
                         ColorTheme (exists today, user-selectable, importable)
                         soyehtDark · dracula · monokai · … · custom/imported
                                        │
                                        ▼
                          SoyehtAppPalette (color roles, derived)
                                        │
        DesignStyle (NEW) ──────────────┤
        classic · neumorphic ·          ▼
        (future: neobrutalist)   DesignStyleTokens (shape/elevation/border/spacing)
                                        │
                                        ▼
                     Rendering layer: SwiftUI modifiers + AppKit helpers
                     (facades SoyehtTheme / MacTheme stay as color access)
```

- `classic` = the app exactly as it looks today. It is the default so the
  change is a no-op for existing users.
- Any color theme must render acceptably under any style. The designed
  `neo: classic/midnight/cream` variants become **derivation fixtures** (and
  optionally new built-in color themes), not a parallel color system.

## 4. New types (all in `Packages/SoyehtCore/Sources/SoyehtCore/Theme/`)

### 4.1 `DesignStyle.swift`

```swift
public enum DesignStyle: String, CaseIterable, Codable, Sendable {
    case classic        // current look, default
    case neumorphic     // this plan implements it
    // case neobrutalist  // added only when its skin is actually built

    /// Styles offered in Settings. Lets us land a case before exposing it.
    public static var selectable: [DesignStyle] { [.classic, .neumorphic] }
}
```

Persistence: new property `TerminalPreferences.designStyle`
(key `soyeht.design.style`, default `"classic"`), same file and pattern as
`colorTheme`.

Store: `DesignStyleStore` (mirrors `TerminalThemeStore`): `shared`,
`activeStyle`, `setActiveStyle(_:)` which persists and posts the
notification.

Notification: `Notification.Name.soyehtDesignStyleChanged`, declared in
SoyehtCore (NOT in the iOS-only `AppNotifications.swift`) so both apps and
the package can observe it. For symmetry, add a SoyehtCore-level
re-export/alias of `.soyehtColorThemeChanged` later if we ever move it; not
required now.

### 4.2 `SoyehtAppPalette` extension — new derived color roles

Neumorphism needs color roles that do not exist yet. They are derivable from
any `TerminalColorTheme`, so they belong in the palette (style-agnostic
colors; the *style* decides whether to use them):

| New role | Derivation rule (from `backgroundHex`, luminance-aware) | Fixture: Cloud `#E0E5EC` | Fixture: Midnight `#23262C` |
|---|---|---|---|
| `wellHex` (recessed bg) | darken(bg, ~5%) | `#D8DEE8` | `#1D2025` |
| `surfaceRaisedHex` (exists — verify ≈ lighten(bg, ~4%)) | lighten(bg, ~4%) | `#E8EDF4` | `#282C33` |
| `shadowDarkHex` | light bg: darken(bg, ~22%); dark bg: darken(bg, ~40%) | `#A6B4C8` | `#14161A` |
| `shadowLightHex` | light bg: `#FFFFFF`; dark bg: lighten(bg, ~32%) | `#FFFFFF` | `#363C46` |
| `accentShadowHex` | accent @ 30–35% alpha | `#5B7CFA59` | `#3EE0A64D` |
| `screenHex` (dark inset media area) | near-black tinted toward bg hue | `#262B36` | `#101216` |

The exact percentages are tuned so the fixtures match the designed values
within a small tolerance (unit-tested, see §8). The third designed variant
(`cream`, bg `#EFE7DC`) is a third fixture row.

Optional (recommended, cheap): ship 2–3 new built-in `TerminalColorTheme`s
tuned for the neumorphic look — "Neo Cloud" (`#E0E5EC` family), "Neo
Midnight" (`#23262C`), "Neo Cream" (`#EFE7DC`) — so the shipped design is
reproducible exactly. They are ordinary color themes; they also work under
`classic`.

### 4.3 `DesignStyleTokens.swift` — the style axis

One value type, one static constructor per style. Not a protocol hierarchy —
styles differ in *values*, the renderer differs in *treatment* (§5).

```swift
public struct DesignStyleTokens: Sendable, Equatable {
    // Shape
    public var radiusCard: CGFloat        // neo: 20  · classic: current values
    public var radiusControl: CGFloat     // neo: 12
    public var radiusPill: CGFloat        // 999

    // Elevation (the heart of the style)
    public enum ElevationTreatment: Sendable, Equatable {
        case flat                                          // classic (hairline borders)
        case dualSoft(offset: CGFloat, blur: CGFloat)      // neumorphic raised
        case dualSoftInset(offset: CGFloat, blur: CGFloat) // neumorphic pressed/well
        case hardOffset(offset: CGSize)                    // neobrutalist (future)
    }
    public var raisedLarge: ElevationTreatment   // neo: dualSoft(7, 16)  — panes, cards
    public var raisedMedium: ElevationTreatment  // neo: dualSoft(4–5, 8–10) — controls, rows
    public var raisedSmall: ElevationTreatment   // neo: dualSoft(3, 6)   — dots, chips
    public var recessed: ElevationTreatment      // neo: dualSoftInset(3, 6) — active tab, wells
    public var accentGlow: (offset: CGFloat, blur: CGFloat)? // neo: (6, 14) on accent CTAs

    // Borders
    public var borderWidth: CGFloat        // classic: hairline · neo: 0 · brutal: 2–3
    public var usesInkBorders: Bool        // neobrutalist only

    // Spacing (introduced now, values = today's de-facto grid)
    public var spacingS: CGFloat, spacingM: CGFloat, spacingL: CGFloat

    public static func tokens(for style: DesignStyle) -> DesignStyleTokens
}
```

Facade access, same pattern as colors: `DesignStyleTokens.active` reads
`DesignStyleStore.shared.activeStyle`. Everything stays cheap computed
values; a redraw after the notification picks up the new style, exactly like
color changes today.

Deliberately **not** in tokens for now: fonts. The mock uses Nunito/Poppins/
Quicksand (`$neo-font`) and the brutalist mock uses Fredoka/Bangers, but the
app has a strong bundled identity (JetBrains Mono + SF via `Typography`).
Bundling 3–5 new fonts is a product decision with licensing/size costs.
Phase 1 keeps `Typography` untouched; a `fontOverride` token slot can be
added later without breaking anything. **Reviewers: please confirm.**

## 5. Rendering layer — where styles actually become pixels

Migrating ~1000 color call sites is out of scope and unnecessary (color
facades keep working unchanged). What changes per style is the **surface
treatment** of a small set of container/control archetypes. From the mocks,
the complete archetype inventory is:

| Archetype | In the neo mock | Classic treatment | Neumorphic treatment |
|---|---|---|---|
| Raised card / pane container | terminal panes, drawer rows, notes card | flat fill + hairline border + small shadow | `surfaceRaised` fill, `radiusCard`, dual soft shadows (dark +x+y / light −x−y) |
| Recessed well | drawer background, active tab | secondary fill | `well` fill, inset-style dual shadow |
| Pill control | tabs, Spaces/Claws buttons, icon buttons | current buttons | `surfaceRaised` pill + dualSoft(4,8); active = `well` + recessed |
| Accent CTA | "Claws" button, "Browse Claw Store" | accent fill button | accent fill + `accentGlow` shadow, `onAccent` text |
| Status dot / chip | pane status dots, LIVE badge | plain circle | tiny raised treatment (dualSoft(2,4)) |
| Screen inset | webcam/metrics dark area | dark fill | `screen` fill + small inset shadow |

Implementation:

- **SwiftUI (shared, in SoyehtCore):** `Theme/StyleModifiers.swift` with a
  tiny API surface:
  - `.soyehtSurface(_ role: SurfaceRole)` where
    `enum SurfaceRole { case raisedCard, raisedControl, well, pill(isActive:), accentCTA, screen }`
  - Internally reads `DesignStyleTokens.active` + `SoyehtAppPalette` roles
    and applies fill/radius/border/shadows. Dual shadows in SwiftUI are just
    two `.shadow` modifiers.
- **AppKit (macOS-only helper, in SoyehtMac):** `StyleKit.swift` with
  `applySurface(_ role:, to view: NSView)`. Note: a `CALayer` has a single
  shadow, so `dualSoft` needs two stacked background layers (or one
  container layer + one background layer, each carrying one shadow). This is
  the one genuinely fiddly platform piece — keep it in a single helper so no
  view hand-rolls it.
- **`classic` must be a visual no-op.** Two options:
  - (a) classic tokens reproduce today's exact values, views migrate to
    modifiers and we verify no visual change; or
  - (b) modifiers short-circuit for `.classic` and leave the view's existing
    inline styling untouched during migration.
  Recommendation: **(b) during migration, (a) as the end state** — it lets us
  land the neumorphic skin without first pixel-auditing every classic view.
  **Reviewers: please confirm.**

## 6. Scope of the first implementation

The mocks are macOS main-window screens (1280×800, traffic lights, tab
chrome, bento pane area, Claw Drawer). First target = **macOS app main
window**, chrome only:

1. Window chrome + tab bar (pill tabs, sidebar toggle, Spaces/Claws buttons).
2. Pane containers in the pane area (header row with status dot, title in
   JetBrains Mono, action icons; body unchanged).
3. Claw Drawer (well background, raised claw rows with avatar/status/chat
   button, accent "Browse Claw Store" CTA).

Explicit non-goals of phase 1:

- The **terminal grid content** (SwiftTerm) keeps being colored by the
  active `TerminalColorTheme` exactly as today. The style skins the chrome
  *around* the terminal; it never touches ANSI colors. (This is precisely
  what makes "color theme keeps working" true by construction.)
- iOS screens: adopt later; the tokens/modifiers are shared from day one so
  iOS adoption is mechanical.
- Neobrutalism: prepared for (tokens enum case slot, `hardOffset` treatment,
  `usesInkBorders`), but no skin is built.

## 7. Settings UI

- iOS (`TerminalApp/Soyeht/Settings/`): new row "App Style" in
  `SettingsRootView` + `SettingsRoute.designStyle` +
  `Appearance/DesignStyleView.swift` (cards with mini-previews, same UX
  pattern as `ColorThemeView`). New i18n keys `settings.row.designStyle`,
  `designstyle.*`.
- macOS: a "Style" picker in the existing appearance surface (menu or the
  theme window `ThemeCatalogWindowController`), reading/writing the same
  `DesignStyleStore`. Both apps share persistence via the SoyehtCore store,
  but note UserDefaults are per-app sandboxes — style is per-device-per-app,
  same as color theme today. (If cross-device sync is ever wanted, that is a
  separate feature for both axes.)
- Selection flow mirrors color exactly: `DesignStyleStore.shared
  .setActiveStyle(...)` → persists → posts `.soyehtDesignStyleChanged` →
  views already observing color re-render; add the style notification to the
  same observers.

## 8. Testing

1. **Palette derivation fixtures (unit, SoyehtCore):** for the three designed
   backgrounds (`#E0E5EC`, `#23262C`, `#EFE7DC`), assert the derived
   `well/surfaceRaised/shadowDark/shadowLight/accentShadow` are within a
   small ΔE/component tolerance of the designed hex values (§4.2 table).
2. **Token table tests:** `DesignStyleTokens.tokens(for:)` snapshot per style
   (radii, elevation cases, glow) so accidental drift is caught.
3. **Persistence/round-trip:** `TerminalPreferences.designStyle` default,
   set/read, unknown-value fallback to `.classic` (forward compatibility if
   a future style name is read by an old build).
4. **Classic no-op guard:** during migration option (b) this is trivial; at
   end state (a), add snapshot tests (macOS) of the migrated components in
   `classic` vs. reference images.
5. **Live switching:** UI test or manual checklist — switch style with a
   terminal session open; switch color theme while in neumorphic style; both
   must re-render without restart (same mechanism as color today).
6. Optional boundary test in the spirit of `LegacyBoundaryUsageTests`: after
   a component is migrated, forbid new inline `.shadow(`/`cornerRadius`
   literals in the migrated macOS chrome files (regex-based, warn-level to
   start).

## 9. Phases (each lands independently)

- **Phase 0 — Foundations (SoyehtCore only, zero visual change):**
  `DesignStyle`, `TerminalPreferences.designStyle`, `DesignStyleStore`,
  `.soyehtDesignStyleChanged`, `DesignStyleTokens` (classic + neumorphic
  values), `SoyehtAppPalette` new roles + derivation, all §8.1–8.3 tests.
- **Phase 1 — Rendering layer:** `StyleModifiers.swift` (SwiftUI) +
  `StyleKit.swift` (AppKit dual-shadow helper), with `.classic`
  short-circuit. No adoption yet.
- **Phase 2 — Neumorphic skin, macOS main window:** migrate tab chrome, pane
  containers, Claw Drawer to the archetype modifiers (§6). Behind the style
  setting; default remains `classic`.
- **Phase 3 — Settings pickers** (macOS + iOS) + live-switch wiring + i18n.
- **Phase 4 (future, separate plan):** iOS adoption of the neumorphic skin;
  neobrutalist tokens + skin (`hardOffset` shadows, ink borders, stroke
  traffic lights, `c-*` palette mapping, font decision); possible
  neo-tuned built-in color themes if not shipped in Phase 0.

## 10. Decision points for reviewers

1. **Fonts:** keep JetBrains Mono + SF in all styles for now (my
   recommendation), or bundle the mock fonts (Nunito/Poppins/Quicksand) as
   part of the neumorphic identity?
2. **Classic migration strategy:** short-circuit (b) during migration, exact
   tokens (a) as end state — agreed?
3. **New built-in color themes** ("Neo Cloud/Midnight/Cream") in Phase 0 or
   defer?
4. **macOS-first** (matches the mocks) with iOS in Phase 4 — agreed? The
   working color-theme picker is on iOS, so iOS users won't see the style
   axis until Phase 3/4 unless we add the iOS picker earlier.
5. **AppKit dual-shadow approach:** stacked layers in a single `StyleKit`
   helper — any known perf concern with many panes? (SwiftUI side is
   trivially two `.shadow`s.)
6. Naming: `DesignStyle` / `DesignStyleTokens` / `DesignStyleStore` /
   `SurfaceRole` — bikeshed now, rename is cheap pre-implementation.
