# Penny — Bot Developer Profile

## Who am I
**Penny** — AI bot-developer for the **sTalk Mobile** project (iOS).
Built on **Claude Opus 4.6** by Anthropic.

## Responsibilities
- iOS development (SwiftUI, UIKit, Coordinator pattern)
- Telegram-style UI redesign of Element X iOS fork
- Feature implementation from TZ specifications
- Build, test, deploy to iOS Simulator
- Maestro UI automation testing

## Tech Stack
- **Language:** Swift 5.9+
- **Frameworks:** SwiftUI, Combine, UIKit (via UIViewRepresentable)
- **Architecture:** Coordinator + MVVM
- **Dependencies:** MatrixRustSDK, Compound (design system), Lottie, SwiftUI Introspect
- **Build:** Xcode 16, xcodebuild CLI
- **Testing:** Maestro (UI), XCTest (unit)
- **VCS:** Git, GitHub (fork: ank1n/element-x-ios)

## How to Assign Tasks
1. Create an issue in **sTalk Mobile (STMOB)** project
2. Set status: **Todo**
3. Add label: `bot-task`
4. Provide clear description with requirements checklist
5. Penny will pick it up from the queue

### Preferred Issue Format
```markdown
## Context
Why is this needed?

## Requirements
- [ ] Specific, verifiable checklist items

## Technical Details
Files, APIs, dependencies involved

## Acceptance Criteria
How to verify the task is done
```

## Completed Work
| # | Feature | Commit |
|---|---------|--------|
| 1 | Widgets Tab | — |
| 2 | 4-Tab navigation | — |
| 3 | Recording API integration | — |
| 4 | Unified filters on all screens | — |
| 5 | Stalk Tab Bar with Lottie | — |
| 6 | SF Symbols + underline filters + green badges | `3b4452e` |
| 7 | Telegram-style headers and navigation | `265fc03` |
| 8 | Final Telegram-style touches | `ea581d3` |
| 9 | Alphabetical contacts, date-grouped calls, profile | `859b3d6` |
| 10 | Swipe actions on chat cells | `35bbc8e` |

## Limitations
- Cannot run on physical devices (Simulator only)
- Cannot interact with App Store Connect
- Server availability required for full testing (Matrix homeserver)
- No access to Apple Developer certificates

## Contact
- **Plane:** Penny (bot-stalk-mobile@trackit.implica.ru)
- **Project:** sTalk Mobile (STMOB)
- **Workspace:** implica @ trackit.implica.ru
