# Installer and cask lifecycle

Application, CLI, replaceable daemon and stable session host have separate version/capability information. Installation atomically verifies executable files and stages service changes without authorizing process interruption. An active shell includes an idle prompt and its background programs. A timeout or failed health check preserves the uncertain owner. Different build numbers and modification times never authorize stopping sessions.

`harness-cli uninstall --if-empty` removes the verified local service and installed tools only after an atomic empty shutdown or positively absent ownership. `--force` explicitly interrupts the verified owner’s shells and programs; an interactive prompt also describes that interruption. Unknown ownership never becomes permission to signal a process or remove files. `--service-only` retains installed tools. User settings, layouts, credentials, managed worktrees, captured history, shell integration and unrelated bin files remain preserved. Explicit homes cannot uninstall the normal user’s shared service. Service backends themselves hold the inactive-owner fence and validate the definition’s recorded home before removing it, even if another caller bypasses the CLI.

The Linux archive installer separately provides complete binary-directory exchange, checksums, architecture validation, recovery and rollback. See [Linux packaging](LINUX-PACKAGING.md). Installation or rollback does not automatically replace a running session host. Restarting it remains an explicit interruption or requires every shell/process to close.

Create a local Homebrew cask from **supplied verified artifact metadata**, without uploading or changing release workflows:

```sh
python3 Scripts/generate-cask.py --metadata artifact.json > harness.rb
```

The input is schema 1 with an explicit `version`, stable HTTPS `url` and lowercase 64-character `sha256` for an existing artifact containing `Harness.app`. The generator prints a complete cask; it does not invent artifact URLs/checksums, download an artifact, install anything or publish a tap. Metadata is bounded and safely quoted without Ruby interpolation. Homebrew verifies the supplied artifact checksum. The cask installs the application and exposes its bundled CLI. On first application launch, the existing guarded installation path configures per-user tools/service.

GUI upgrades and GUI-only cask uninstall leave the independently installed session service running so terminal programs survive. The cask intentionally issues no signal, launchctl removal, wildcard deletion or history zap. To remove both GUI and service, run `harness-cli uninstall --if-empty` after closing shells, then `brew uninstall --cask harness`; the cask’s visible caveat gives that exact flow. A user may instead retain headless work while removing the GUI. Explicit user data removal remains separate from package uninstall. This uses the current declarative [Homebrew cask lifecycle](https://docs.brew.sh/Cask-Cookbook), without deprecated flight blocks or an upgrade hook that kills terminals.

No packaging path claims that processes survive reboot. The [session survival table](SESSION-SERVICE-UPDATES.md) distinguishes app closure, daemon replacement, session-host failure, logout, sleep and reboot.

The macOS packaging and preview scripts assemble a complete sibling bundle before exchanging it atomically. Failed assembly leaves the prior bundle available. Destination symlinks and non-owned directories are refused; packaging does not stop session hosts. Preview GUI replacement retains its isolated host and shells. Service-manager calls drain bounded output and expire after ten seconds; an activation error is surfaced rather than treated as proof of a loaded service. Generated launchd plists preserve special characters in file paths through XML escaping.

Systemd starts the exact literal executable path with environment substitution disabled (`ExecStart=:`), while still escaping systemd specifiers. Dollar signs in an installation path cannot change the daemon's argument identity or sibling session-host discovery.

macOS helpers retain their own app bundles, provisioning profiles and signatures. Stable public tool paths point into installer-owned `.tool-bundles` directories; verified bundle exchanges preserve existing running executable inodes. Installation validates ownership, refuses unrelated aliases/directories, synchronizes staged files and directories, and retains a recovery copy if rollback fails. Refresh checks the complete bundle, including profile/resource changes. An explicit Harness home installs tools there without changing the user's login service or shell profiles.

Developer ID signing requires macOS profiles for the application and each helper, authorizing the selected certificate, component ID and shared history group. Set `HARNESS_PROVISIONING_PROFILE_DIRECTORY` to the directory containing `Harness.provisionprofile`, `HarnessSessionHost.provisionprofile`, `HarnessDaemon.provisionprofile` and `harness-cli.provisionprofile`. Preflight validates all four before modifying signing state. Local signed previews use `HARNESS_PREVIEW_SIGNING_IDENTITY` and the real bundle ID that their profiles authorize. `--sign-only` always skips notarization, including when notarization credentials are already configured.

This development work does not create or publish a release, change version numbers, upload builds, or alter release workflows. Local build, signing and installer verification remain in scope.
