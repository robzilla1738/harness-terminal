#!/usr/bin/env python3
"""Validate supplied Apple profiles before applying restricted entitlements."""
import datetime
import fnmatch
import hashlib
import pathlib
import plistlib
import re
import subprocess
import sys


def prepare(app, identity, supplied_team, profiles, output):
    base = plistlib.loads((pathlib.Path(__file__).resolve().parent.parent / "Harness.entitlements").read_bytes())
    identity_hash = None
    team = supplied_team
    if identity != "-":
        identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True, timeout=10)
        for digest, label in re.findall(r'\d+\) ([A-Fa-f0-9]{40}) "([^"]+)"', identities):
            if identity == label or identity.lower() == digest.lower():
                identity_hash = digest.lower()
                match = re.search(r'\(([A-Z0-9]{10})\)$', label)
                team = team or (match.group(1) if match else "")
                break
        if not identity_hash or not re.fullmatch(r"[A-Z0-9]{10}", team):
            raise ValueError("Select an available signing identity and its APPLE_TEAM_ID.")
        if not profiles:
            raise ValueError("Set HARNESS_PROVISIONING_PROFILE_DIRECTORY to matching macOS profiles named Harness.provisionprofile, HarnessSessionHost.provisionprofile, HarnessDaemon.provisionprofile and harness-cli.provisionprofile. Shared Keychain access requires these profiles; signing bare tools is insufficient.")
    targets = [(name, app / "Contents" / "Helpers" / (name + ".app"))
               for name in ["HarnessSessionHost", "HarnessDaemon", "harness-cli"]]
    targets.append(("Harness", app))
    validated = []
    for name, bundle in targets:
        info = plistlib.loads((bundle / "Contents" / "Info.plist").read_bytes())
        entitlements = dict(base)
        profile = None
        if identity == "-":
            entitlements.pop("keychain-access-groups", None)
        else:
            path = pathlib.Path(profiles) / (name + ".provisionprofile")
            if path.stat().st_size > 4 * 1024 * 1024:
                raise ValueError(name + ": provisioning profile exceeds the file-size limit.")
            profile = path.read_bytes()
            decoded = plistlib.loads(subprocess.check_output(["security", "cms", "-D", "-i", str(path)], timeout=10))
            allowed = decoded.get("Entitlements", {})
            expiration = decoded.get("ExpirationDate")
            if not isinstance(expiration, datetime.datetime) or expiration.replace(tzinfo=datetime.timezone.utc) <= datetime.datetime.now(datetime.timezone.utc):
                raise ValueError(name + ": provisioning profile is expired or has no expiry.")
            if team not in decoded.get("TeamIdentifier", []) or "OSX" not in decoded.get("Platform", []):
                raise ValueError(name + ": profile must authorize this team on macOS.")
            certificates = decoded.get("DeveloperCertificates", [])
            if not any(hashlib.sha1(certificate).hexdigest() == identity_hash for certificate in certificates):
                raise ValueError(name + ": profile does not authorize the selected signing certificate.")
            app_id = team + "." + info["CFBundleIdentifier"]
            allowed_id = allowed.get("com.apple.application-identifier", allowed.get("application-identifier", ""))
            group = team + ".com.robert.harness.history"
            if not fnmatch.fnmatchcase(app_id, allowed_id) or not any(fnmatch.fnmatchcase(group, item) for item in allowed.get("keychain-access-groups", [])):
                raise ValueError(name + ": profile must authorize " + app_id + " and " + group + ".")
            entitlements["keychain-access-groups"] = [group]
            entitlements["com.apple.application-identifier"] = app_id
            entitlements["com.apple.developer.team-identifier"] = team
        validated.append((name, bundle, profile, entitlements))
    # No bundle is changed until every supplied profile has passed validation.
    output.mkdir(parents=True, exist_ok=True)
    for name, bundle, profile, entitlements in validated:
        if profile is not None:
            (bundle / "Contents" / "embedded.provisionprofile").write_bytes(profile)
        (output / (name + ".plist")).write_bytes(plistlib.dumps(entitlements))


if __name__ == "__main__":
    try:
        prepare(pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4], pathlib.Path(sys.argv[5]))
    except (ValueError, OSError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        raise SystemExit("Signing refused: " + str(error))
