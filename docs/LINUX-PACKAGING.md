# Linux archives and installation

Harness’s Linux scope is the headless session host, replaceable daemon and CLI. The application remains macOS-only. The archive includes all three executables, artifact metadata, checksums, licenses and the reviewed installer. The theme catalog contains **514 bundled themes**. The iOS companion remains privately available; it is not part of the Linux archive.

`packaging/linux-lock.json` pins separate x86_64 and arm64 Swift 6.0.3 container digests and the SQLite development package version, and fixes the build worker count at six so host CPU counts do not change compiler inputs. The runtime baseline is **Ubuntu 22.04, glibc 2.35 or newer, and the distribution libraries listed in each artifact’s `runtime_packages`**. Swift is linked statically. Distribution libraries, including curl, OpenSSL, SQLite and the C++ runtime, still matter: static Swift linking does not make a binary independent of those dependencies. Python 3 is needed by the archive installer and proof tools, not by the running daemon or CLI.

Build locally with an available Docker-compatible runtime:

```sh
python3 Scripts/package-linux.py --context YOUR_CONTEXT
```

The builder snapshots the selected working-tree source, including uncommitted development changes, and records its SHA-256 identity. The snapshot stays local. Both architectures build from that identical snapshot in the locked toolchains with separate named caches. No release workflow, publishing, CI matrix or recurring validation is involved. The source path is normalized during compilation. Archives omit DWARF debug sections and compiler-only incremental module fingerprints; runtime reflection metadata, unwind tables and ordinary symbols remain. Archive entry order, modes, owner names/IDs, times and gzip timestamp are deterministic. The builder records actual ELF architectures, per-binary SHA-256 values, dynamic libraries and package versions. An unresolved or dynamic Swift runtime dependency fails packaging.

Outputs are `harness-linux-x86_64.tar.gz` and `harness-linux-arm64.tar.gz`, their `.sha256` files, and readable artifact JSON. Verify the archive’s SHA-256 against supplied trusted artifact metadata. An adjacent checksum file detects corruption but is not an independent authenticity boundary. Install the declared distribution runtime packages through your normal package manager before installing Harness.

```sh
python3 Scripts/install-linux-archive.py --archive harness-linux-arm64.tar.gz --sha256 TRUSTED_SHA256
```

The installer checks the complete archive hash, bounded safe archive paths, component set, individual executable hashes, actual ELF architecture and runtime dependencies before applying anything. It does not execute startup commands from imported configurations. It preserves unrelated regular files and symlinks in the existing `bin` directory; unsupported entries require an explicit move before installation. Owner checks, no-follow opens, a kernel installation lock, verified temporary files and fsync protect installation state. Linux `renameat2(RENAME_EXCHANGE)` swaps the complete binary directory atomically. There is no remove-then-copy interval or mixed-version binary group after the swap.

An interruption-safe journal distinguishes prepared and exchanged directories by all preserved file/link identities. Run the installer again, or use `--recover`, to finish the verified transaction. Changed staging/current files are refused. One verified previous binary directory is retained for `--rollback`; altered backups remain preserved. Rollback exchanges complete directories and does not infer success from file modification times. Nothing in installation, recovery or rollback stops a running shell, daemon or session host. Their pending update/restart policy remains governed by protocol/capability compatibility and live process ownership.

```sh
python3 Scripts/install-linux-archive.py --recover
python3 Scripts/install-linux-archive.py --rollback
```

Pass `--service` to use the installed CLI’s existing guarded systemd-user installation. An active or uncertain owner keeps its service definition/update staged; service installation is not permission to interrupt programs. Explicit `--home` / `HARNESS_HOME` installations do not modify the normal user’s shared service. Configure a separate reviewed service if that is desired. The normal user home follows XDG data/runtime directories. `loginctl enable-linger USER` is a separate administrator action when survival after logout is required; no installer silently changes lingering.

Source installation remains an explicit option through `Scripts/install-linux.sh --source`, requiring a local Swift 6 toolchain. Archive installation does not require a Swift toolchain.

Runtime verification uses each pinned Ubuntu image with the declared distribution libraries, with no Swift installed. It runs the CLI and the isolated reusable session-survival workload against the packaged host/daemon and verifies installation/rollback/recovery in a private temporary home. A successful builder link alone is not runtime evidence. The proof never points at an existing Harness home or user service.

Live processes survive app closure and compatible daemon replacement because the session host owns their PTYs. Host failure, logout without the required service/session policy, and OS reboot are different events. Saved layout/history can be restored after reboot; live processes cannot survive reboot. Linux history is explicitly owner-only plaintext storage for the macOS-specific encryption feature, not mislabeled encryption.

The Swift 6.0.3 Linux linker emits an upstream Foundation `mktemp` warning. Its pinned implementation opens the generated path with `O_CREAT | O_EXCL` and retries collisions; Harness does not suppress that diagnostic. Sensitive Harness history and installation writes use their own owner-checked, no-follow temporary-file primitives. See the [pinned Foundation implementation](https://github.com/swiftlang/swift-foundation/blob/swift-6.0.3-RELEASE/Sources/FoundationEssentials/Data/Data%2BWriting.swift). Swift, Foundation and Dispatch license texts are included alongside dependency notices.

An independent clean-cache build exposed differing DWARF/module fingerprints despite identical runtime code and data. Removing those compiler-only artifacts makes release binaries reproducible across clean and reused caches. The [pinned Swift compiler](https://github.com/swiftlang/swift/blob/swift-6.0.3-RELEASE/lib/IRGen/IRGenModule.cpp) identifies `.swift_modhash` as an incremental-compilation hash; it is not terminal or Swift reflection state. Runtime survival and dependency checks run on the final normalized binaries.
