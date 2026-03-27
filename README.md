# _bootstrap

Lightweight development environment setup script for linux server.

## 🚀 Quick Start

```bash
cd _bootstrap
chmod +x setup.sh
./setup.sh
exec bash
```

## ✨ What It Does

- **Miniconda** - Python environment manager
- **GitHub Auth** - SSH key (auto-generated) on regular servers; HTTPS token (PAT) on Kubernetes — set `GITHUB_TOKEN` env var to skip the prompt
- **Dev Tools** - Installs curl, wget, git, git-lfs, tree, htop, tmux (via conda)
- **Git Config** - Prompts for your Git commit name/email and sets common defaults
- **Config Files** - Deploys .gitignore_global, .tmux.conf, and aliases to home directory

## 📁 Directory Structure

```
setup.sh               # Installs the bootstrap environment and config files

config/
├── .gitignore_global  # Global gitignore patterns
├── .tmux.conf         # tmux settings (mouse, history, colors)
└── .bashrc            # Shell settings (added to ~/.bashrc)

gpu_idle/
└── gpu_dummy.py       # Keeps GPUs busy when idle, pauses on real workloads
```
