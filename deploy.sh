#!/bin/bash
# Builds the site and pushes it to the master branch of miloradbozic.github.io (served by GitHub Pages).
set -e
SITE_DIR=$(mktemp -d)
git clone -q -b master https://github.com/miloradbozic/miloradbozic.github.io.git "$SITE_DIR"
find "$SITE_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
hugo -d "$SITE_DIR"
cd "$SITE_DIR"
git add -A
git commit -m "${1:-rebuilding site $(date)}"
git push origin master
rm -rf "$SITE_DIR"
