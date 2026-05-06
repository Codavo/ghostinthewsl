#!/bin/bash
# Downloads conpty.dll + OpenConsole.exe from the official NuGet package.
# Usage: ./scripts/update-conpty.sh [version]
# If no version specified, downloads latest known good version.
set -euo pipefail

VERSION="${1:-1.22.250314001}"
DEST="dist/windows/conpty"
MYTMP=$(mktemp -d)
trap "rm -rf $MYTMP" EXIT

echo "Downloading CI.Microsoft.Windows.Console.ConPTY v${VERSION}..."
curl -sL -o "$MYTMP/conpty.nupkg" \
  "https://www.nuget.org/api/v2/package/CI.Microsoft.Windows.Console.ConPTY/${VERSION}"

echo "Extracting x64 binaries..."
mkdir -p "$DEST"
python3 -c "
import zipfile
z = zipfile.ZipFile('$MYTMP/conpty.nupkg')
for name in z.namelist():
    normalized = name.replace('\\\\', '/')
    if normalized == 'runtimes/win10-x64/native/conpty.dll':
        with open('$DEST/conpty.dll', 'wb') as f:
            f.write(z.read(name))
        print('  conpty.dll')
    elif normalized == 'build/native/runtimes/x64/OpenConsole.exe':
        with open('$DEST/OpenConsole.exe', 'wb') as f:
            f.write(z.read(name))
        print('  OpenConsole.exe')
"

echo "$VERSION" > "$DEST/VERSION"

echo "Done. Files in $DEST:"
ls -la "$DEST"
echo "Version: $(cat "$DEST/VERSION")"

# Also copy to src/conpty/ for @embedFile
SRC_DEST="src/conpty"
mkdir -p "$SRC_DEST"
cp "$DEST/conpty.dll" "$SRC_DEST/conpty.dll"
cp "$DEST/OpenConsole.exe" "$SRC_DEST/OpenConsole.exe"
echo "Copied to $SRC_DEST/ for embedding."
echo ""
echo "Remember to commit the updated binaries."
