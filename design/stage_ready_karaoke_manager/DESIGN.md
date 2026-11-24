---
name: Stage-Ready Karaoke Manager
colors:
  surface: '#111317'
  surface-dim: '#111317'
  surface-bright: '#37393e'
  surface-container-lowest: '#0c0e12'
  surface-container-low: '#1a1c20'
  surface-container: '#1e2024'
  surface-container-high: '#282a2e'
  surface-container-highest: '#333539'
  on-surface: '#e2e2e8'
  on-surface-variant: '#d8c3ad'
  inverse-surface: '#e2e2e8'
  inverse-on-surface: '#2f3035'
  outline: '#a08e7a'
  outline-variant: '#534434'
  surface-tint: '#ffb95f'
  primary: '#ffc174'
  on-primary: '#472a00'
  primary-container: '#f59e0b'
  on-primary-container: '#613b00'
  inverse-primary: '#855300'
  secondary: '#f0bd82'
  on-secondary: '#472a00'
  secondary-container: '#62400f'
  on-secondary-container: '#ddac72'
  tertiary: '#8fd5ff'
  on-tertiary: '#00344a'
  tertiary-container: '#1abdff'
  on-tertiary-container: '#004966'
  error: '#ffb4ab'
  on-error: '#690005'
  error-container: '#93000a'
  on-error-container: '#ffdad6'
  primary-fixed: '#ffddb8'
  primary-fixed-dim: '#ffb95f'
  on-primary-fixed: '#2a1700'
  on-primary-fixed-variant: '#653e00'
  secondary-fixed: '#ffddb8'
  secondary-fixed-dim: '#f0bd82'
  on-secondary-fixed: '#2a1700'
  on-secondary-fixed-variant: '#62400f'
  tertiary-fixed: '#c5e7ff'
  tertiary-fixed-dim: '#7fd0ff'
  on-tertiary-fixed: '#001e2d'
  on-tertiary-fixed-variant: '#004c6a'
  background: '#111317'
  on-background: '#e2e2e8'
  surface-variant: '#333539'
typography:
  display-stage:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 64px
    fontWeight: '700'
    lineHeight: 76px
    letterSpacing: -0.02em
  display-stage-mobile:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 36px
    fontWeight: '700'
    lineHeight: 44px
    letterSpacing: -0.01em
  headline-lg:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 32px
    fontWeight: '600'
    lineHeight: 40px
  headline-md:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 24px
    fontWeight: '600'
    lineHeight: 32px
  headline-sm:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 20px
    fontWeight: '600'
    lineHeight: 28px
  title-md:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 16px
    fontWeight: '600'
    lineHeight: 24px
  body-md:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 14px
    fontWeight: '400'
    lineHeight: 20px
  body-sm:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 13px
    fontWeight: '400'
    lineHeight: 18px
  label-lg:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 14px
    fontWeight: '500'
    lineHeight: 20px
    letterSpacing: 0.01em
  label-md:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 12px
    fontWeight: '500'
    lineHeight: 16px
    letterSpacing: 0.02em
  label-sm:
    fontFamily: Noto Sans, Noto Sans Devanagari
    fontSize: 11px
    fontWeight: '600'
    lineHeight: 14px
    letterSpacing: 0.04em
rounded:
  sm: 0.125rem
  DEFAULT: 0.25rem
  md: 0.375rem
  lg: 0.5rem
  xl: 0.75rem
  full: 9999px
spacing:
  gutter: 1rem
  margin: 1.5rem
  space-xs: 0.25rem
  space-sm: 0.5rem
  space-md: 1rem
  space-lg: 1.5rem
  space-xl: 2rem
---

## Brand & Style

This design system is built for a solo performer operating an offline, stage-ready karaoke manager on iPad and desktop. The interface balances two distinct environments: a calm, dense, enterprise-grade workspace for managing libraries and setlists backstage, and an ultra-legible, zero-glare teleprompter for live stage performance.

The visual language blends **Corporate / Modern** precision with **High-Contrast** clarity. Backstage views prioritize information density, predictable spatial organization, and generous 44pt+ touch targets for effortless iPad navigation. Stage views strip away all chrome, leaving only high-contrast lyrics and essential transport controls against a near-black canvas that prevents projector glare in dark venues.

## Colors

The palette is anchored in a **dark** color mode engineered for low-light venues and projector compatibility.

- **Canvas & Surfaces:** The primary background uses near-black (`#111317`) rather than pure `#000000` to eliminate harsh contrast halation and projector glare. Elevated surfaces step up cleanly through dark slate tiers (`#1A1D24` for cards, sidebars, and table headers; `#232730` for active rows, popovers, and interactive controls).
- **Typography:** Primary text uses crisp off-white (`#F3F4F6`) for maximum legibility, while secondary metadata, timestamps, and inactive lyric lines use muted slate (`#9CA3AF`).
- **Primary Accent:** Warm stage amber (`#F59E0B`) serves as the single primary accent color, reserved exclusively for active lyric lines, primary call-to-action buttons, and active playback indicators.
- **Semantic Status Colors:** Status colors are restricted strictly to song-state chips so they never compete with stage cues:
  - `ready`: Emerald (`#10B981`)
  - `needs_sync`: Amber (`#F59E0B`)
  - `needs_lyrics`: Rose (`#F43F5E`)
  - `processing`: Slate (`#64748B`)

## Typography

The type system pairs **Noto Sans** with **Noto Sans Devanagari** across all levels to guarantee seamless baseline alignment, consistent x-height, and unified stroke weight when Latin and Devanagari scripts appear side by side in song titles, setlists, and live lyrics.

- **Stage Lyric Display:** `display-stage` (`64px`) is built for distance legibility on stage monitors and projectors. On smaller viewports, it scales down to `display-stage-mobile` (`36px`).
- **Tabular Numerals:** All numeric data—including BPM, song durations, countdown timers, and setlist indices—must apply `font-variant-numeric: tabular-nums` so columns align vertically and live timers never jitter.
- **Hierarchy:** Backstage tables use `body-md` (`14px`) and `body-sm` (`13px`) for dense scanning, paired with uppercase or medium-weight `label-md` (`12px`) column headers.

## Layout & Spacing

The layout uses a **12-column fluid grid** with `1rem` (`16px`) gutters and `1.5rem` (`24px`) outer margins on desktop and landscape iPad viewports.

- **Responsive Adaptation:**
  - **Desktop / iPad Landscape (>= 1024px):** 12-column fluid grid. Persistent left navigation rail (`240px`) paired with a fluid main workspace for library tables or split-pane setlist builders.
  - **iPad Portrait (768px – 1023px):** 8-column fluid grid. Navigation collapses into a compact top bar or slide-over drawer to maximize horizontal room for table columns.
  - **Mobile (< 768px):** 4-column fluid grid with `1rem` (`16px`) outer margins. Dense tables reflow into stacked list cards showing title, artist, duration, and status chip.
- **Touch Readiness:** All interactive elements, table rows, and transport controls must maintain a minimum **44pt (44px) height** for reliable touch operation on iPad during live sets.

## Elevation & Depth

Visual hierarchy relies on **tonal layers** reinforced by **low-contrast outlines** rather than drop shadows, which are ineffective against near-black backgrounds.

- **Surface Tiers:**
  - **Level 0 (Base Canvas):** `#111317` for the main application background and full-screen stage mode.
  - **Level 1 (Containers):** `#1A1D24` for sidebars, cards, table headers, and persistent transport bars.
  - **Level 2 (Interactive / Elevated):** `#232730` for hovered table rows, active setlist items, dropdown menus, and modal dialogs.
- **Ghost Borders:** Use subtle `1px` borders (`rgba(255, 255, 255, 0.08)`) to separate adjacent tonal surfaces without adding visual noise. Active or focused inputs use a `1px` warm stage amber (`#F59E0B`) border.

## Shapes

The design system uses a **soft** shape language (`roundedness: 1`, `0.25rem` base radius). Small interactive elements such as buttons, inputs, and table checkboxes use `0.25rem` (`4px`), cards and panels use `0.5rem` (`8px`), and modal dialogs or stage transport bars use `0.75rem` (`12px`). Status chips use full pill rounding (`9999px`) to distinguish them from rectangular action buttons.

## Components

- **Buttons:** Primary actions (e.g., *Start Stage Mode*, *Add to Setlist*) use solid warm stage amber (`#F59E0B`) fills with dark `#111317` text for high contrast. Secondary actions use `#232730` fills with `#F3F4F6` text and a `1px` ghost border. Minimum height is `44px`.
- **Status Chips:** Compact, pill-shaped badges (`24px` height, `label-md`) used exclusively for song states. Each chip pairs a `12%` opacity tinted background with full-saturation text and a `6px` leading dot: `ready` (`#10B981`), `needs_sync` (`#F59E0B`), `needs_lyrics` (`#F43F5E`), and `processing` (`#64748B`).
- **Library & Setlist Tables:** Dense, enterprise-grade tables with `44px` minimum row height, `1px` horizontal dividers (`rgba(255, 255, 255, 0.06)`), and `#232730` hover states. Numeric columns (BPM, Duration, Key) are right-aligned with `tabular-nums`.
- **Checkboxes & Radio Buttons:** `20px` visual controls wrapped in a `44px × 44px` invisible hit target. Unchecked states use a `1px` `#9CA3AF` border; checked states fill with `#F59E0B` and a `#111317` checkmark.
- **Input Fields:** `44px` height, `#111317` background inside `#1A1D24` containers, `1px` ghost border, and `#F59E0B` focus ring.
- **Cards:** `#1A1D24` surface with `0.5rem` radius, `1px` ghost border, and `1rem` (`16px`) internal padding.
- **Stage Lyric Display:** Full-screen `#111317` canvas. The active lyric line renders in `display-stage` (`64px`) in warm stage amber (`#F59E0B`), while upcoming lines render in `#9CA3AF` at `40%`–`60%` opacity to guide the performer's eye without distraction.