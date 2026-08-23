# Handoff: Prognosify — AI Hospital Dashboard (20 screens)

## Overview
Prognosify is an AI-assisted hospital dashboard for three roles: **doctors** (risk flags, prognosis reports, labs, AI assistant), **receptionists** (front desk, check-in queue, booking, registration, billing), and **patients** (portal: home, booking, results, messages, care plan). All AI content is mocked/canned — no live model calls in the design.

## About the Design Files
The files in this bundle are **design references created in HTML** — a clickable prototype showing intended look and behavior, not production code to copy directly. The task is to **recreate these designs in the target codebase's environment** (React, Vue, etc.) using its established patterns and libraries — or, if no codebase exists yet, choose an appropriate stack (e.g. React + Tailwind) and implement there.

- `Prognosify App.dc.html` — all 20 screens with navigation. Each screen lives in a `<sc-if value="{{ is.<key> }}">` block; markup inside is plain HTML with inline styles (single source of truth for all measurements/colors).
- `SideNav.dc.html` — the shared staff sidebar (doctor + reception variants), 232px wide.
- Ignore the `<x-dc>`/`sc-if`/`dc-import`/`{{ }}` wrappers — they are prototype plumbing. Treat each screen block as a static HTML/CSS spec.

## Fidelity
**High-fidelity.** Colors, typography, spacing, and copy are final intent. Recreate pixel-perfectly, adapting only to the target design system where one exists.

## Design Tokens
- Font: **Geist** (Google Fonts), weights 400/500/600/700
- Primary accent: `#1D4ED8` (hover `#1E40AF`); accent tint bg `#EDF2FE`, tint border `#C9D8FA`
- Ink/navy (dark surfaces, headings): `#0F1C2E`; body text `#0F1C2E`; muted `#5B6B7F`; faint `#8A97A8`
- App background: `#F4F6F9` (staff), `#FBFCFD` (patient portal); cards `#FFFFFF`
- Borders: `#DDE3EB` (cards/inputs), `#EEF2F6` (row dividers)
- Risk colors — high: text `#B42318`, bg `#FEF5F4`, border `#F1D3D0`; medium: `#B54708` / `#FEFAF0` / `#F3E3C2`; low/good: `#116B3F` / `#F0F7F2` / `#CFE6D8`
- Dark AI panels: bg `#0F1C2E`, label `#8FB0FF`, body `#C7D2E4`, track `#22344E`
- Radii: cards 12–14px, inputs/buttons 8px, chips/pills 16px (12px for status pills), sidebar items 7px
- Type scale: page title 17px/600 (topbar), section header 15px/600, body 13.5–14px, meta 12–12.5px, KPI numbers 26px/700, table headers 12px/600 uppercase +0.03em
- Layout: staff screens = 232px sidebar + fluid main; topbar 64px; content padding 24px 28px; card padding 18–24px; grid/flex gaps 10–20px

## Screens & Navigation Map
Keys match the prototype's screen state. Arrows = click targets.

**Access**
1. `login` — split screen: dark navy brand panel (38%, min 420px) + centered 400px form. Sign in → `docDash`; Forgot password → `forgot`; "Demo as" Doctor/Receptionist/Patient → `docDash`/`recDash`/`patHome`.
2. `forgot` — centered 440px card; both buttons → `login`.
3. `settings` — doctor shell; left sub-nav (200px: Profile, Notifications, AI preferences, Security, Care team); Profile card (2-col field grid), AI preferences card (3 toggles: risk flags ON, confirm-before-chart ON, daily email OFF), Save button.

**Doctor** (sidebar: Dashboard, Patients, Schedule, Labs, AI assistant, Settings, Log out)
4. `docDash` — 4 KPI cards (Patients 42, High-risk flags 5 red, Appointments 11, Labs 8) → patients/schedule/labs; 1.5fr/1fr grid: AI risk-flag list (4 tinted rows with confidence %, → `patientDetail`) + Today's schedule card + dark "AI daily brief" card → `aiChat`.
5. `patients` — filter chips (All 42 / High risk 5 / Inpatient 6 / Recently seen); table (Patient, MRN, Status, Primary condition, AI risk pill, Last visit), 8 rows, hover bg `#F8FAFC`, row → `patientDetail`; pagination footer.
6. `patientDetail` — Rosa Delgado, 71F, MRN 104-882. Header: back link, avatar, name + High-risk pill, demographics line, actions (Add note, Order labs, **AI prognosis report** → `prognosis`). Main: 4 vitals cards (HR 104 red, BP 96/61, Temp 38.4 amber, SpO₂ 93%), Recent labs table (Lactate 3.1 critical, WBC, CRP, Creatinine), Timeline card. Right rail 360px: dark AI prognosis card (sepsis 92% + ICU 54% progress bars, drivers text, Open full report → `prognosis`), Medications, Care team.
7. `prognosis` — report header (back → `patientDetail`, "Model v4.2" pill, Export PDF, Add to chart). Left: 3 risk cards (Sepsis 92%, ICU 54%, LOS 9–12 days) with progress bars; Contributing factors card (5 labeled weight bars, +0.31 … −0.09); disclaimer strip. Right rail 380px: Recommended actions (3 checkbox cards + "Accept all"), Risk trajectory bar chart (7 bars, escalating color), Ask-the-AI card → `aiChat`.
8. `schedule` — Day/Week toggle, date pager; time-grid list with appointment blocks (blue-tinted, left 3px accent border; appointment blocks → `patientDetail`); right rail 320px: Day summary + dark AI scheduling note.
9. `labs` — filter chips (All 8 / Abnormal 3 / Reviewed); table (Patient, Panel, Flag pill, Resulted, AI note, "Review →" → `patientDetail`).
10. `aiChat` — 760px centered thread; user bubbles right (`#1D4ED8`, radius 14/14/4/14), AI bubbles left (white card); action chips under first AI reply → `prognosis`/`patientDetail`; composer with 3 suggestion chips, input, Send; disclaimer line 11.5px `#8A97A8`.

**Receptionist** (sidebar: Front desk, Check-in queue, Book appointment, Register patient, Billing)
11. `recDash` — header actions → `register`/`booking`; 4 KPIs (Waiting 7 → `checkin`, Appointments 64, No-show risk 6, Pending $4,210 → `billing`); Next arrivals list (Check in buttons → `checkin`; amber no-show-risk row with Call button); right rail: Clinic load bars (Cardiology 85%, Radiology 92% amber, Gen med 64%, Pediatrics 41%) + dark AI tip.
12. `checkin` — status chips (Waiting 7 / In room 5 / Done 18); queue cards (grid: queue #, patient, provider, appt, waiting, action). Row 3 amber (32 min wait, Notify provider); walk-in row → `register`; dashed AI estimate strip → `booking`.
13. `booking` — left form card 400px (patient, visit type, provider, duration segmented 15/30/45, AI suggestion strip, Confirm → `recDash`); right: 5-day slot grid, AI-recommended slot `9:00 ★` highlighted with 2px accent border.
14. `register` — 3-step indicator (Identity · Insurance · Consent); Identity card (2-col fields) with amber duplicate-match warning; Visit reason card with "AI triage: routine · Gen. medicine" chip; Cancel → `checkin`, Continue button.
15. `billing` — chips (Pending 9 / Denied 2 / Paid); 3 KPIs (Outstanding $4,210, Denial risk 3, Collected $1,880 green); invoice table (status pills: Copay due, Auth missing red, Covered, 21 days overdue; actions: Collect, Request auth, Details, Send reminder); dashed AI denial-warning strip.

**Patient portal** (top nav 64px: Home, Book visit, Results, Messages, Care plan; avatar PN `#0F6E5D`; bg `#FBFCFD`; centered content 760–960px)
16. `patHome` — greeting; Next appointment card (date tile, Confirm / Reschedule → `patBook`) + New result card (HbA1c 8.9%, "Needs attention") → `patResults`; 3 cards (care plan → `patCare`, messages w/ unread badge → `patMessages`, book → `patBook`); dark health-trend banner with mini bar chart.
17. `patBook` — step 2 of 3; In person / Video toggle; provider row; 4 slot cards (first marked "Recommended" green); AI note about morning adherence; Back / Confirm → `patHome`.
18. `patResults` — hero HbA1c card (amber border): value, gradient range bar (green→amber→red) with marker at 8.9, plain-language explanation, actions → `patMessages`/`patBook`; results table (Fasting glucose slightly high, Cholesterol in range, eGFR in range).
19. `patMessages` — 300px conversation list (active item accent-tinted with 3px left border) + thread pane (grey AI-free bubbles left, blue patient bubbles right) + composer.
20. `patCare` — plan header (Week 7 of 12); Today checklist card (2 done green ✓ tiles, 2 pending with "Log it" link); Goals card (3 progress bars: HbA1c 35% amber, walks 80% green, adherence 96% green); Medications card with "Request refill"; dark "Why this plan" card.

## Interactions & Behavior
- Navigation is instant screen swap (no route transitions in prototype); production should use real routes per screen key.
- Hover states: cards/rows lift via border-color → `#1D4ED8` or bg `#F8FAFC`; primary buttons darken to `#1E40AF`.
- The floating "☰ All 20 screens" switcher (bottom-right) is a **prototype-only review tool** — do not implement.
- Auth is mocked: Sign in routes straight to the doctor dashboard; "Demo as" buttons emulate role-based landing (real app: route by role claim after auth).
- All AI copy (risk scores, briefs, chat replies, suggestions) is canned; production should render the same layouts from API data, and every AI surface keeps its disclaimer text.

## State Management
Prototype state is minimal by design: `screen` (current view key) + `navOpen` (switcher). Production needs: auth/role session, patient list + filters, selected patient, prognosis report data, schedule/queue data, conversation threads, care-plan task completion. Sensible mock fixtures for all of these are embedded verbatim in the screen markup.

## Assets
No image assets. Logo is a typographic mark: accent square (radius ~7–9px, `#1D4ED8`) with white "P" + "Prognosify" wordmark. Icons are text glyphs in the prototype (←, →, ▾, ✓, ★, 🔔) — replace with the codebase's icon set (e.g. Lucide).

## Files
- `Prognosify App.dc.html` — all 20 screens (search `data-screen-label="…"` to jump to a screen)
- `SideNav.dc.html` — staff sidebar component (props: `role` = doctor|reception, `active` key)
