---
layout: page
title: "Manage Dotfiles with Dotbot"
date: 2021-10-10
permalink: /dotbot/
---

I spent a weekend switching my dotfiles manager from yadm to Dotbot. This post is a quick Dotbot tutorial and a record of that migration.

# yadm

yadm is an open‑source dotfiles manager (Yet Another Dotfiles Manager).

I’ve been using yadm since I first decided to manage my dotfiles. My initial reasons:

1. Zero config, works out of the box.
2. No manual symlink setup; it doesn’t touch your existing files.
3. Uses git for syncing and history.

Getting started with yadm is straightforward. First install it (e.g. via Homebrew):

```bash
brew install yadm
```

Then:

```bash
yadm init
yadm add ~/.vimrc
yadm commit
```

Three steps and your `~/.vimrc` is under yadm’s control. Unlike traditional dotfile setups, you don’t have to create a dedicated dotfiles directory, copy files into it, and then create symlinks back.

If you’re thinking “these commands look a lot like git”, you’re right. From a user’s point of view, yadm is just a thin wrapper around git. You can think of yadm as a bare git repository with its work tree set to `$HOME` (there’s a good article explaining this pattern [here](https://www.ackama.com/what-we-think/the-best-way-to-store-your-dotfiles-a-bare-git-repository-explained/)).

The underlying repo lives in `$XDG_DATA_HOME/yadm/repo.git`. yadm mostly just configures git appropriately and adds a few dotfiles‑specific conveniences.

For beginners, yadm is very friendly and was a great fit for the "shell beginner me". But over time, some pain points emerged:

1. Tools like `lazygit` don’t play nicely, since this is a bare repo glued onto `$HOME`.
2. Shell completion performance is poor; hitting Tab can [freeze the shell](https://github.com/TheLocehiliosan/yadm/issues/359) until you kill the process.

To be fair, fish’s own completion is pretty good, and I don’t change dotfiles constantly, so I tolerated these issues for quite a while. It “worked well enough”.

# Dotbot

A while back someone in a chat group shared Dotbot, and it immediately looked appealing. I procrastinated for a long time, but finally bit the bullet and migrated from yadm to Dotbot.

First, a quick intro.

Dotbot is a lightweight, open‑source dotfiles tool. All it really does is read a config file, create the requested symlinks, and clean up dead links. Version control is entirely delegated to git.

OK, let’s dive in.

## Preparation

First, go to your dotfiles directory (create one if you don’t already have it—name doesn’t matter):

```bash
cd dotfiles
```

Initialize a git repo there:

```bash
git init
```

Then install Dotbot:

```bash
pip3 install dotbot
```

(Alternatively you can vendor Dotbot as a git submodule; the README explains that approach.)

Next, copy your existing config files into the dotfiles directory. One important point: inside this dotfiles repo, you’re free to organize files however you want. The directory layout doesn’t have to mirror the original locations.

## Configuring Dotbot

With the prep done, we can configure Dotbot. It reads a config file in either YAML or JSON. The docs use YAML, so I’ll stick with that. One big gotcha: YAML’s indentation rules are strict and subtle; if Dotbot errors on run, use a `yaml2json` tool to inspect what your YAML _actually_ parses into (many GitHub issues in the tracker boil down to bad YAML).

Create the config file:

```bash
touch install.conf.yaml
```

A Dotbot config is a list of **commands**. Dotbot currently supports five command types: `link`, `clean`, `create`, `shell`, and `defaults`.

### `link`

This is the core of Dotbot. It describes which files or directories to link.

The simplest form:

```yaml
- link:
    ~/.vimrc: vimrc
    ~/.gitconfig: gitconfig
```

This tells Dotbot to symlink `~/.vimrc` → `dotfiles/vimrc` and `~/.gitconfig` → `dotfiles/gitconfig`.

`link` supports various options (e.g. `create`, `relink`, `force`); see the README’s [link format section](https://github.com/anishathalye/dotbot#format) for all of them.

### `clean`

`clean` scans directories for dead symlinks and removes them.

Why is this needed? Suppose you move `vimrc` from `dotfiles/vimrc` to `dotfiles/vim/vimrc` and update your `link` config to:

```yaml
- link:
    ~/.vimrc: vim/vimrc
```

Before you recreate the symlink, you need something to find and remove the old `~/.vimrc → dotfiles/vimrc` link. That’s what `clean` is for.

You can specify multiple directories:

```yaml
- clean: ["~", "~/.config"]
```

`clean` itself supports options (e.g. `force`, `exclude`); see the [docs](https://github.com/anishathalye/dotbot#format-3).

My current `clean` config:

```yaml
- clean:
    ~/:
    ~/.config:
      recursive: true
```

I do a simple clean in `$HOME`, and a recursive clean in `$XDG_CONFIG_HOME`, since that’s where many per‑app subdirectories live.

### `create`

`create` creates empty directories. Why? Because on a fresh machine, directories like `~/.config` or `~/.ssh` might not exist yet. You can use `create` to ensure they’re present:

```yaml
- create:
    ~/.ssh:
      mode: 0700
    ~/.config:
```

Since `link` also supports `create: true` to auto‑create parent directories, I haven’t needed `create` much myself yet.

Again, see the [docs](https://github.com/anishathalye/dotbot#format-1) for options.

### `shell`

`shell` runs arbitrary shell commands. I don’t currently need it, but it’s handy for bootstrapping:

```yaml
- shell:
    - ["echo 'Hello from Dotbot'", "Printing greeting"]
```

Note: the README’s examples tend to put `shell` at the end, but that’s not required—you can mix commands in any order and have multiple `shell` entries.

### `defaults`

`defaults` lets you set default options for other commands. For example, instead of writing `create: true` under every single link, you can do this once:

```yaml
- defaults:
    link:
      create: true
      relink: true
      force: true
```

### Full Example

Here’s a trimmed‑down version of my current config (only a few links shown as examples):

```yaml
- defaults:
    link:
      create: true
      relink: true
      force: true

- clean:
    ~/:
    ~/.config:
      recursive: true

- link:
    ~/.config/alacritty/alacritty.yml: alacritty/alacritty.yml
    ~/.config/nvim/init.vim: nvim/init.vim
    ~/.gitconfig: git/gitconfig
    ~/.tmux.conf: tmux/tmux.conf
```

## Running Dotbot

With `install.conf.yaml` in place, we can run Dotbot:

```bash
dotbot -c path/to/install.conf.yaml
```

Done. After this, just commit and push your dotfiles repo as usual.

If you find yourself annoyed at typing that long command, wrap it in an `install.sh` script. That also gives you a place to add more bootstrap logic later.

On a new machine, you just clone the repo and run `./install.sh`.

If Dotbot errors, add `-v` for verbose output. In my experience, almost all errors are malformed YAML. When that happens, don’t panic—run your config through `yaml2json` and check whether it matches what you intended.

# Conclusion

Dotbot is small and easy to use. It saves you from hand‑maintaining symlinks, and because it delegates version control to plain git (unlike yadm’s specialized wrapper), you avoid extra cognitive overhead. The earlier yadm‑related issues also disappear.

This post introduced yadm and Dotbot and showed how to set up Dotbot to manage your dotfiles. I hope it’s helpful if you’re considering making the switch.

# References

- [Yet Another Dotfiles Manager - yadm](https://yadm.io/)
- [anishathalye/dotbot: A tool that bootstraps your dotfiles ⚡️](https://github.com/anishathalye/dotbot)
