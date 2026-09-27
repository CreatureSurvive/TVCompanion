#!/bin/sh
# Copies named screenshot attachments from an .xcresult into a folder.
# Landscape (TV) screenshots become <name>.jpg; portrait (phone) ones become
# <name>.png scaled to 600 pixels wide.
set -eu
result=$1
out=$2
tmp=$(mktemp -d)
xcrun xcresulttool export attachments --path "$result" --output-path "$tmp" >/dev/null
mkdir -p "$out"
python3 - "$tmp" "$out" <<'PY'
import json, os, subprocess, sys
tmp, out = sys.argv[1:]

def size(path):
    info = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", path], capture_output=True, text=True).stdout.split()
    return int(info[info.index("pixelWidth:") + 1]), int(info[info.index("pixelHeight:") + 1])

for test in json.load(open(os.path.join(tmp, "manifest.json"))):
    for attachment in test["attachments"]:
        name = attachment.get("suggestedHumanReadableName", "")
        base = name.split("_")[0] if "_" in name else os.path.splitext(name)[0]
        source = os.path.join(tmp, attachment["exportedFileName"])
        width, height = size(source)
        if width > height:
            target = os.path.join(out, base + ".jpg")
            args = ["sips", "-s", "format", "jpeg", "-s", "formatOptions", "85"]
            if width > 1920:
                args += ["--resampleWidth", "1920"]
        else:
            target = os.path.join(out, base + ".png")
            args = ["sips", "--resampleWidth", "600"]
        subprocess.run(args + [source, "--out", target], capture_output=True, check=True)
        print(target)
PY
