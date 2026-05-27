# Harness v1.0.0 release checklist

Manual verification before tagging `v1.0.0`.

## Build and package

- [ ] `make release` completes without errors
- [ ] `Harness.app` contains `Harness`, `HarnessDaemon`, `harness-cli`, and `Harness.icns`
- [ ] `make dmg` produces `Harness.dmg` that mounts and drags to Applications
- [ ] Optional: `SIGNING_IDENTITY`, `APPLE_ID`, `APPLE_TEAM_ID`, `APPLE_APP_PASSWORD` set; `./Scripts/sign-and-notarize.sh` succeeds

## Session and layout

- [ ] New workspace (`Cmd+Shift+N`) persists after quit and relaunch
- [ ] New session creates a new sidebar row with its own tab group
- [ ] New tab (`Cmd+T`) stays inside the active session, and splits (`Cmd+D` / `Cmd+Shift+D`) persist after relaunch
- [ ] Workspace switcher selects correct workspace; tab list updates
- [ ] Active tab highlight matches focused pane after reload

## Terminals and agents

- [ ] Git branch label updates in sidebar when cwd changes
- [ ] `harness-cli notify --surface "$HARNESS_SURFACE" --body "test"` marks only the correct tab
- [ ] `Cmd+Shift+U` jumps to the waiting tab
- [ ] Bell / desktop notification delegates update tab title or waiting state

## Settings and UI

- [ ] Settings (`Cmd+,`): theme, font size, keep-sessions apply live
- [ ] Command palette (`Cmd+K`) lists discoverable actions
- [ ] `Cmd+\` toggles sidebar; `Cmd+W` closes active tab
- [ ] About panel shows version and harness-cli path

## harness-cli

- [ ] `harness-cli ping` succeeds with app or daemon running
- [ ] `harness-cli list-surfaces` maps UUIDs to tab titles
- [ ] `harness-cli new-workspace --name api` resolves by name
- [ ] `harness-cli new-session --workspace api` creates a separate session group
- [ ] `harness-cli install` copies binary and prints PATH line

## Clean machine

- [ ] DMG installs on macOS 14+ without Xcode installed
- [ ] First launch creates default workspace and offers harness-cli install
