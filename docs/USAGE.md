# Blog publishing from Obsidian (EN-only)

This repo can be used as your GitHub Pages publishing target while keeping your Obsidian vault untouched.

## What this does

- Publishes only files ending with ` (EN).md`
- Reads from your Obsidian vault (`~/Documents/Obsidian/Blog` by default)
- Rewrites Obsidian wikilinks like `[[post_2]]` and `[[post_2|custom text]]` into normal Markdown links
- Copies non-Markdown assets from each post folder (images, etc.)
- Skips posts marked as draft in Obsidian front matter (`draft: true`)

## Folder assumptions in Obsidian

```text
Blog/
  post_1/
    content.md
    content (EN).md
  post_2/
    content.md
    content (EN).md
```

## Usage

From this repository root:

```bash
python3 scripts/sync_posts.py
```

This generates publishable pages under `published/`:

```text
published/
  post-1/
    index.md
  post-2/
    index.md
```

## Optional flags

```bash
python3 scripts/sync_posts.py \
  --source ~/Documents/Obsidian/Blog \
  --output published \
  --no-clean
```

- `--source`: custom Obsidian blog folder
- `--output`: output directory in this repo
- `--no-clean`: keep existing generated files

## GitHub Pages setting

In GitHub repo settings for Pages, set source to deploy from branch and root folder (this repo root). Jekyll will render the generated `published/<slug>/index.md` pages.

If you want these pages under a different URL prefix, change the `permalink` format in the script.

## Local preview (one command)

From the repo root, run:

```bash
./scripts/preview_pages.sh
```

Then open: `http://127.0.0.1:4000`

Notes:

- The script auto-runs `bundle install` when needed.
- This local preview uses Jekyll 4 + Minima for compatibility with modern Ruby.
- If Bundler is missing, install Ruby + Bundler first (`brew install ruby && gem install bundler`).
