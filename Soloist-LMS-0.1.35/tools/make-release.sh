#!/bin/sh
# Builds dist/Soloist-LMS-<version>.zip from the Soloist folder and updates
# repo.xml with the matching version, SHA1 and download URL.
# Run from the repository root on macOS or Linux:  sh tools/make-release.sh
set -eu
cd "$(dirname "$0")/.."

VERSION=$(sed -n 's:.*<version>\(.*\)</version>.*:\1:p' Soloist/install.xml)
[ -n "$VERSION" ] || { echo "No <version> in Soloist/install.xml" >&2; exit 1; }
ZIP="Soloist-LMS-$VERSION.zip"
URL="https://github.com/osdieman/Spotify-Soloist-LMS/releases/download/v$VERSION/$ZIP"

rm -rf dist && mkdir -p dist/stage/Plugins
cp -R Soloist dist/stage/Plugins/Soloist
find dist/stage -name '.DS_Store' -delete
find dist/stage -name '._*' -delete
(cd dist/stage && COPYFILE_DISABLE=1 zip -qrX "../$ZIP" Plugins)
rm -rf dist/stage

if command -v sha1sum >/dev/null 2>&1; then SHA=$(sha1sum "dist/$ZIP" | cut -d' ' -f1)
else SHA=$(shasum -a 1 "dist/$ZIP" | cut -d' ' -f1); fi

# Only touch attributes of the <plugin> element (not the XML declaration).
V="$VERSION" S="$SHA" U="$URL" perl -0pi -e '
  s{(<plugin\b[^>]*?\s)version="[^"]*"}{$1version="$ENV{V}"}s;
  s{(<plugin\b[^>]*?\s)sha="[^"]*"}{$1sha="$ENV{S}"}s;
  s{(<plugin\b[^>]*?\s)url="[^"]*"}{$1url="$ENV{U}"}s;
' repo.xml

echo "Built   dist/$ZIP"
echo "SHA1    $SHA"
echo
echo "Next:"
echo "  1. GitHub > Releases > Draft a new release, tag v$VERSION, attach dist/$ZIP"
echo "  2. Commit the updated repo.xml"
