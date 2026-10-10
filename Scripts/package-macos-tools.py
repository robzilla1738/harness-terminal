#!/usr/bin/env python3
"""Put each Keychain-using helper in a profile-capable app bundle.

The public Contents/MacOS paths remain aliases; installed tools must retain the
complete helper bundle rather than copying its executable out of the bundle.
"""
import pathlib
import plistlib
import sys


def package(app):
    contents = app / "Contents"
    metadata = plistlib.loads((contents / "Info.plist").read_bytes())
    for name, suffix in [("HarnessSessionHost", "sessionhost"),
                         ("HarnessDaemon", "daemon"), ("harness-cli", "cli")]:
        source = contents / "MacOS" / name
        bundle = contents / "Helpers" / (name + ".app")
        executable = bundle / "Contents" / "MacOS" / name
        if not source.is_symlink():
            executable.parent.mkdir(parents=True, exist_ok=True)
            source.replace(executable)
            source.symlink_to("../Helpers/" + name + ".app/Contents/MacOS/" + name)
        elif source.resolve() != executable.resolve() or not executable.is_file():
            raise ValueError("Unexpected helper alias: " + str(source))
        info = {"CFBundleExecutable": name,
                "CFBundleIdentifier": metadata["CFBundleIdentifier"] + "." + suffix,
                "CFBundleName": name, "CFBundlePackageType": "APPL",
                "CFBundleInfoDictionaryVersion": "6.0", "LSBackgroundOnly": True,
                "CFBundleVersion": metadata["CFBundleVersion"],
                "CFBundleShortVersionString": metadata["CFBundleShortVersionString"],
                "LSMinimumSystemVersion": metadata.get("LSMinimumSystemVersion", "15.0")}
        if "HarnessPreviewHome" in metadata:
            info["HarnessPreviewHome"] = metadata["HarnessPreviewHome"]
        (bundle / "Contents" / "Info.plist").write_bytes(plistlib.dumps(info))


if __name__ == "__main__":
    package(pathlib.Path(sys.argv[1]))
