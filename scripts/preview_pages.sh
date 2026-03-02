#!/usr/bin/env bash
set -euo pipefail

if ! command -v bundle >/dev/null 2>&1; then
  echo "Bundler is not installed. Install Ruby + Bundler first, then retry."
  echo "Example (macOS): brew install ruby && gem install bundler"
  exit 1
fi

bundle config set path vendor/bundle >/dev/null 2>&1 || true
bundle check >/dev/null 2>&1 || bundle install

exec bundle exec jekyll serve --livereload
