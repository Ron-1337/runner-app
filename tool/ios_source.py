#!/usr/bin/env python3
"""Writes the iOS app source (AltStore / SideStore format) for a release.

    tool/ios_source.py <ipa> <tag> <owner/repo> <out.json>

The source lists the IPA attached to the release <tag>, with the version and
bundle id read from the IPA itself, so the source always matches what it
points to. CI attaches it to every release; its stable address is
https://github.com/<owner/repo>/releases/latest/download/source.json
"""

import datetime
import json
import os
import plistlib
import sys
import zipfile


def app_info(ipa):
    with zipfile.ZipFile(ipa) as z:
        name = next(
            n for n in z.namelist()
            if n.startswith("Payload/") and n.count("/") == 2 and n.endswith(".app/Info.plist")
        )
        return plistlib.loads(z.read(name))


def main(ipa, tag, repo, out):
    info = app_info(ipa)
    raw = f"https://raw.githubusercontent.com/{repo}/main"
    icon = f"{raw}/ios/Runner/Assets.xcassets/AppIcon.appiconset/Icon-App-1024x1024@1x.png"
    version = {
        "version": info["CFBundleShortVersionString"],
        "buildVersion": info.get("CFBundleVersion", ""),
        "date": datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "localizedDescription": f"Runner Remote {tag}",
        "downloadURL": f"https://github.com/{repo}/releases/download/{tag}/{os.path.basename(ipa)}",
        "size": os.path.getsize(ipa),
        "minOSVersion": info.get("MinimumOSVersion", "15.0"),
    }
    app = {
        "name": "Runner Remote",
        "bundleIdentifier": info["CFBundleIdentifier"],
        "developerName": repo.split("/")[0],
        "subtitle": "远程查看和操作 Runner 的会话",
        "localizedDescription": "Runner Remote 是 Runner 的手机客户端：通过 runner-server "
        "连接电脑上的 Runner，查看会话、接管终端，并接收会话需要输入、完成或失败的推送通知。",
        "iconURL": icon,
        "tintColor": "#00D98A",
        "category": "developer",
        "versions": [version],
        # For AltStore and SideStore releases that predate "versions".
        "version": version["version"],
        "versionDate": version["date"],
        "versionDescription": version["localizedDescription"],
        "downloadURL": version["downloadURL"],
        "size": version["size"],
    }
    source = {
        "name": "Runner Remote",
        "identifier": f"{info['CFBundleIdentifier']}.source",
        "subtitle": "Runner Remote 官方软件源",
        "website": f"https://github.com/{repo}",
        "iconURL": icon,
        "tintColor": "#00D98A",
        "apps": [app],
        "news": [],
    }
    with open(out, "w", encoding="utf-8") as f:
        json.dump(source, f, ensure_ascii=False, indent=2)
        f.write("\n")


if __name__ == "__main__":
    if len(sys.argv) != 5:
        sys.exit(__doc__)
    main(*sys.argv[1:])
