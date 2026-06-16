# Murmur — UI/UX Revamp Plan

> Companion to `PLAN.md` (which tracks the engine/feature work). This file tracks
> the **production-grade UI/UX revamp**: a cohesive Apple-native, Liquid-Glass
> design language across every surface.

## Direction (locked)
- **Aesthetic:** Apple-native + **Liquid Glass everywhere** (the floating control
  layer is glass; long-form reading content stays on solid surfaces).
- **Baseline:** **macOS 26 (Tahoe)** — deployment target bumped from 14.0 → 26.0
  so the full Liquid Glass API set is available with no fallbacks.
- **Brand accent:** indigo→violet, matching the app icon gradient
  (`#5C4CED` → `#A345E8`). Accent defined in the asset catalog (light + dark).
- **Scope:** full revamp, phased; each phase ships independently.
- **Out of scope (for now):** licensing / paywall / account UI.

## The glass rule
Glass is for the **control / navigation layer** — the notch, menu-bar popover,
toolbars, sidebars, badges, floating actions. **Never** for body/reading content
(history text, comparison diffs), which sits on solid grouped surfaces. This is
the line between tasteful and "glass soup."

---

## Phase 0 — Foundation & brand spine  ✅
- Bump deployment target 14.0 → 26.0 (`project.yml`); verify Liquid Glass compiles.
- Define the signature accent in `Assets.xcassets/AccentColor.colorset` (light/dark).
- Lock the glass philosophy (control layer only).
- **Verify:** `xcodebuild` green on macOS 26 with glass APIs in use. ✅

## Phase 1 — Design system  ✅
The reusable kit everything else consumes (`Murmur/DesignSystem/`).
- **Tokens:** `Palette` (semantic color), `Typography` (SF Pro scale + Dynamic
  Type), `Metrics` (4-pt `Spacing` + `Radius` scales), `Motion` (shared springs).
- **Components:** `GlassCard` / `GlassPill` (the one glass primitive),
  `StatusBadge` / `StatusChip` / `StatusKind` (icon+color, color-blind safe),
  `EmptyStateView`, `PrimaryButton` / `SecondaryButton`, `SectionHeader`
  (with info-popover to demote always-on help text).
- **`DesignSystemGallery`** — a `#Preview` catalog of the whole language and a
  compile-time consumer proving the kit renders.
- **Deferred to their phases (built where they're consumed):** `PermissionRow`,
  `SettingRow` (Phase 5); diff/list components (Phase 6).
- **Verify:** `xcodebuild` green; gallery renders all tokens + components. ✅

## Phase 2 — The Notch (the hero)  ✅
- Rebuilt `DictationNotchView` so states **morph** with `.blurReplace` + the shared
  `.mSmooth` spring (keyed on phase kind) instead of hard-swapping.
- Waveform redesign: brand-gradient audio-reactive bars with a violet glow and a
  **breathing silence floor** (sine baseline) so the notch always looks alive.
- Replaced the **fake** progress bar with an honest indeterminate sweep
  (`IndeterminateBar`) — no fabricated percentage.
- Streaming preview gets a pulsing red **live dot** + head-truncation.
- `BouncingDots` transcribing indicator; spring-in `ConfirmRow` for done/learned/error.
- Standardized terminal dwell (done 1.6s, learned/error 2.4s); honors Reduce Motion
  throughout (all `TimelineView` animations pause).
- **Deferred:** in-notch **cancel** affordance (needs hotkey/controller state-machine
  wiring — risks the push-to-talk flow; revisit as a focused change) and start/stop
  earcons. Non-notch floating-pill glass styling folds into Phase 3/7.
- **Verify:** `xcodebuild` green; user runs a dictation to review the new look. ✅ (build)

## Phase 3 — Menu bar  ✅
- Moved from `.menu` to a **rich glass popover** (`MenuBarExtra(.window)`),
  `MenuBarPopover` (width 300, tinted with the user's accent).
- Header: app glyph + wordmark + version + a live `StatusBadge` (pulsing dot,
  Ready/Listening/Transcribing/Preparing/Error).
- Inline glass `NoticeRow`s for the Accessibility prompt + "undo learned"; a
  `LastDictationCard` with one-tap **Copy** (✓ feedback); a `GlassEffectContainer`
  row of three glass `QuickTile`s (History / Compare / Settings); footer with the
  trigger hint + a glass Quit.
- **State-reflecting menu-bar icon** (`MenuBarLabel`): waveform → mic.fill →
  ellipsis → warning by status.
- **Glass refinement (v0.3.4→0.3.6, per user feedback):** went full Control-Center —
  `PopoverWindowConfigurator` makes the MenuBarExtra window transparent so the single
  glass panel blurs the desktop directly; then **stripped all inner backgrounds**
  (modules, tile glass, button glass, icon chips) so everything floats flat on the one
  glass surface. Interactive items (tiles, `GhostButtonStyle` for Copy/Quit/notice)
  reveal a faint `primary.opacity` highlight on hover/press only. User: "looking really
  good."
- **Verify:** `xcodebuild` green; reviewed live on the user's Mac. ✅

## Phase 4 — Onboarding / first-run  ✅
- `OnboardingView` + `OnboardingWindowController` — a five-step glass welcome
  (chromeless window, transparent titlebar, accent-glow background): welcome → mic
  (primed) → accessibility (primed) → model pick (status) → **live practice field**
  (focused `TextField`; the real dictation pastes in so the user sees it work, with a
  "you're dictating!" confirmation). Animated progress dots, Back/Continue nav on the
  design-system buttons, permission status auto-refreshes on app re-activate.
- Replaced the old "first launch just opens Settings" with this flow in `AppDelegate`.
- **Refined (v0.4.1, per user):** dropped the model-picker step (model stays in
  Settings as the advanced choice) and replaced it with a **waveform-color** step —
  live `AccentWaveformPreview` on a dark notch-like backing + the 6 swatches, applied
  live via `applyAccent()`.
- **Verify:** `xcodebuild` green; shown on first run (flag reset to preview). ✅

## Phase 5 — Settings  ✅
- Restructured the one long 8-section Form into a **System-Settings-style
  `NavigationSplitView`**: a glass sidebar of 7 categories (General · Dictation ·
  Microphone · Appearance · Vocabulary · Learned Words · **Advanced**) + a grouped
  detail form per category. Window 720×540.
- **Advanced** holds the technical knobs the user wanted there: the speech-model
  picker (+ `StatusChip`) and smart-cleanup (+ cleanup model + status).
- Help text demoted to section `footer`s; permission "Granted" now a `StatusChip`;
  per-category routing via `Bindable<Preferences>` params.
- **Verify:** `xcodebuild` green; open via ⌘, to review. ✅ (build)

## Phase 6 — History & Cleanup Comparison  ✅
- History: **search-match highlighting** (accent-emphasized via AttributedString),
  toolbar **More menu** (Copy All / Export to .txt via `NSSavePanel` / Clear All),
  **Clear All confirmation dialog**, copy ✓ feedback kept, glass list.
- Comparison: **calmer diff** (muted red-strike for removed, plain green for added —
  dropped the heavy bold), **per-row copy menu** (raw / cleaned), glass surface.
- **Deferred (nice-to-have):** sort options, full-text expand, side-by-side diff
  toggle — current inline diff + highlighting covers the core need.
- **Verify:** `xcodebuild` green; reviewed in History/Comparison windows. ✅

## Phase 7 — Brand, motion, accessibility & final polish  ✅
- **App icon refresh** (`tools/make_icon.swift`): custom 7-bar white waveform (mirrors
  the live waveform) on a richer indigo→violet squircle + subtle top sheen; regenerated
  all 10 PNGs.
- **WCAG AA sweep**: Reduce Motion honored on `StatusBadge` pulse (plus notch / onboarding
  preview / live dot already); VoiceOver labels on History rows + Comparison copy menu;
  decorative glyphs marked `accessibilityHidden`; native controls give keyboard nav +
  focus rings; semantic fonts give Dynamic Type; Reduce Transparency falls back via
  `NSVisualEffectView` + `.glassEffect` automatically.
- **Motion**: already on the shared `.mSnappy/.mSmooth/.mBounce/.mQuick` spring set.
- **Cleanup**: removed the now-unused `HistoryWindowController` +
  `CleanupComparisonWindowController`.
- **Verify:** `xcodebuild` green; new icon rendered; reviewed on-device. ✅

---

## Progress log
- **Phase 7 ✅ — Final polish (v0.4.6, branch `claude/phase7-polish`).** Refined the
  **app icon** (custom 7-bar waveform mirroring the live one + sheen, richer gradient;
  regenerated PNGs). **WCAG AA sweep**: Reduce-Motion guard on `StatusBadge`; VoiceOver
  labels on History rows + Comparison copy; decorative glyphs hidden; Reduce Transparency
  auto-handled by the vibrant materials. Removed the dead History/Comparison window
  controllers. (Phases 0–6 merged to main in PR #14 first.) `xcodebuild` → **SUCCEEDED**.
- **History & Comparison folded into Settings (v0.4.5).** Per user — one hub. Added
  `.history` + `.comparison` to `SettingsCategory` (sidebar "Library" section), and a
  `SettingsRouter` (@Observable) so the menu-bar History/Compare tiles **deep-link**
  into the Settings window (`AppDelegate.showHistory/showComparison` set
  `router.category` then show Settings). `SettingsWindowController` now carries the
  SwiftData `ModelContainer` (`.modelContainer`) + router so the embedded `@Query`
  views work. Made `HistoryView` embeddable — dropped the window chrome/NavigationStack
  for an inline **glass search pill** (with clear button + count) + the More menu;
  `CleanupComparisonView` lost its window frame. Standalone History/Comparison window
  controllers now unused. Sidebar regrouped: Setup · Words · Library · Advanced.
  `xcodebuild` → **BUILD SUCCEEDED**.
- **Phase 6 ✅ — History & Comparison polish (v0.4.4).** History: search-match
  highlighting (AttributedString, accent), toolbar More menu (Copy All / Export .txt
  via NSSavePanel / Clear All) + Clear-All confirmation dialog. Comparison: toned-down
  diff (muted red strikethrough + plain green, no heavy bold) + per-row copy menu
  (raw/cleaned). `xcodebuild` → **BUILD SUCCEEDED**.
- **Liquid-glass windows everywhere (v0.4.3).** New reusable `.liquidGlassWindow()`
  (DesignSystem/GlassWindow.swift): a `behindWindow` `NSVisualEffectView` (`.sidebar`
  material) backdrop + a `GlassWindowConfigurator` that makes the host window
  transparent, edge-to-edge (`fullSizeContentView`, clear bg, transparent titlebar).
  Applied to **Settings, History, Comparison, Onboarding**, with inner backgrounds
  cleared (`.scrollContentBackground(.hidden)` on Form/Lists) so the glass shows
  through. Onboarding keeps its accent glow as an overlay on the glass. `xcodebuild`
  → **BUILD SUCCEEDED**.
- **Phase 5 ✅ — Settings redesign (v0.4.2).** Replaced the single long grouped Form
  with a System-Settings-style `NavigationSplitView`: glass sidebar of 7 categories
  (General / Dictation / Microphone / Appearance / Vocabulary / Learned Words /
  Advanced) routed via `Bindable<Preferences>` per-category builders; help text moved
  into section footers; permission "Granted" → `StatusChip`. **Model + smart-cleanup
  pickers now live under Advanced** (per the onboarding decision). Window 720×540.
  `xcodebuild` → **BUILD SUCCEEDED**.
- **Phase 4 ✅ + monochrome accents (v0.4.0).** Built first-run onboarding:
  `OnboardingView` (5 glass steps — welcome / mic / accessibility / model / live
  practice field) in a chromeless `OnboardingWindowController`; wired into
  `AppDelegate` first-launch (replaces "just open Settings"). Practice step uses a
  focused `TextField` that the real dictation pastes into. Also added two **monochrome
  waveform accents** per user — `.white` (pure white on dark / #1C1C1E on light) and
  `.graphite` (Apple gray, adaptive) — to `AccentTheme`; Settings swatches gained a
  hairline border so the white one is visible. `xcodebuild` → **BUILD SUCCEEDED**.
- **Notch vs glass pill, per display (v0.3.8).** Per user: keep the **opaque black
  notch** on the built-in notched display (it can't be glassy — DynamicNotchKit
  hardcodes a black fill to blend with the hardware cutout), but show a **translucent
  Liquid-Glass floating pill** on an external monitor. That's exactly `.auto`
  (`screen.hasNotch ? .notch : .floating`), so reverted style `.floating`→`.auto`.
  The content colors couldn't read the library's resolved style (its `notchStyle`
  env value + `hasNotch` are internal), so `NotchController.updateScreenStyle()`
  mirrors the library's own pick — `NSScreen.screens.first` + the **public**
  `auxiliaryTopLeftArea`/`auxiliaryTopRightArea` — and sets `model.isNotchScreen`
  before each show. `DictationNotchView` uses white + `accent.onDark` on the notch,
  `.primary` + `accent.adaptive` on the glass pill. `xcodebuild` → SUCCEEDED.
- **Phase 3 ✅ — Menu-bar glass popover (v0.3.2).** Replaced the plain text `.menu`
  with a `.window`-style `MenuBarPopover`: glass header (glyph + wordmark + version +
  live `StatusBadge`), inline `NoticeRow`s (Accessibility grant, undo-learned),
  `LastDictationCard` with one-tap copy, a `GlassEffectContainer` of three glass
  `QuickTile`s (History/Compare/Settings), and a footer (trigger hint + glass Quit).
  Added a **state-reflecting menu-bar icon** (`MenuBarLabel`: waveform/mic/ellipsis/
  warning). Popover tinted with the user's `accentTheme`. Injected `Preferences` into
  the menu-bar scene. `xcodebuild` → **BUILD SUCCEEDED**.
- **Accent system + user-selectable waveform color (v0.3.1).** Fixed the washed-out
  indigo-on-dark-glass: replaced the hardcoded brand gradient on the waveform with an
  **adaptive, user-selectable accent**. New `AccentTheme` (DesignSystem) — blue
  (default) / teal / coral / violet, each with a **bright `onDark`** value (for the
  always-dark notch) and a **deep `onLight`** value, plus an `adaptive` (NSColor
  dynamic-provider) for system-following surfaces — no per-background hardcoding.
  `Preferences.accentTheme` persists the choice; `NotchViewModel.accent` drives the
  notch; `WaveformView` now takes a solid `color` (+ matching faint glow) instead of a
  gradient; mic glyph / loading bar / "learned" sparkle all use it. Settings gains an
  **Appearance → Waveform color** swatch picker wired live via `applyAccent()`.
  `xcodebuild` → **BUILD SUCCEEDED**.
- **Phase 2 ✅ — The notch (the hero).** Rebuilt `DictationNotchView` on the design
  system: phase changes now **morph** via `.blurReplace` + `.mSmooth` (keyed on a
  `phaseKey` so partial-text updates don't re-animate). New `WaveformView` — brand-
  gradient bars, violet glow, and a per-bar sine **breathing floor** so silence reads
  as quiet attention, not a dead line (driven by `TimelineView(.animation)`, paused
  under Reduce Motion). Killed the dishonest easing progress bar → `IndeterminateBar`
  (honest moving sweep, no fake %). Streaming preview shows a pulsing red **live dot**;
  transcribing uses `BouncingDots`; done/learned/error use a spring-in `ConfirmRow`
  (checkmark/sparkles/triangle). Standardized notch dwell in `NotchController`
  (done 0.9→1.6s, learned 2.6→2.4s, error 1.8→2.4s). Reduce-Motion honored across all
  animated bits. Deferred in-notch cancel (touches the push-to-talk state machine) +
  earcons. `xcodebuild` → **BUILD SUCCEEDED**.
- **Phase 0 + 1 ✅ — Foundation + design system spine.** Bumped deployment target
  14.0 → **26.0** and set the signature **accent** (indigo `#5C4CED`, dark-mode
  variant) in the asset catalog. Built `Murmur/DesignSystem/`: tokens — `Palette`
  (brand gradient + semantic/status/surface colors), `Typography` (`.mDisplay`…
  `.mMono`, all Dynamic-Type-backed), `Metrics` (`Spacing` 4-pt scale + `Radius`),
  `Motion` (`.mSnappy/.mSmooth/.mBounce/.mQuick/.mWaveform` springs); components —
  `GlassCard`/`GlassPill` (the single `.glassEffect` primitive, tint + interactive),
  `StatusKind`/`StatusBadge`/`StatusChip` (icon **and** color, never color alone),
  `EmptyStateView`, `PrimaryButton`/`SecondaryButton` (`.glassProminent`/`.glass`),
  `SectionHeader` (info-popover to retire always-on help paragraphs); plus
  `DesignSystemGallery` (`#Preview` catalog + compile consumer). Confirmed the full
  Liquid Glass API set (`.glassEffect(_:in:)`, `Glass.regular.tint().interactive()`,
  `GlassEffectContainer`, `.buttonStyle(.glass/.glassProminent)`) compiles on macOS
  26 / Xcode 26.5. `xcodebuild` → **BUILD SUCCEEDED**. Existing views unchanged yet
  — they migrate onto the kit starting Phase 2 (the notch).
