# _bootstrap

Lightweight development environment setup script for linux server.

## Quick Start

```bash
cd _bootstrap
./setup.sh
exec bash
```

## What It Does

- **Miniconda** - Python environment manager
- **GitHub Auth** - SSH key (auto-generated) on regular servers; HTTPS token (PAT) on Kubernetes — set `GITHUB_TOKEN` env var to skip the prompt
- **Dev Tools** - Installs curl, wget, git, git-lfs, tree, htop, tmux (via conda)
- **Git Config** - Prompts for your Git commit name/email and sets common defaults
- **Config Files** - Deploys .gitignore_global, .tmux.conf, and aliases to home directory

`setup.sh` can be run again. Changed home config files are backed up under
`~/.bootstrap-backups/` before they are replaced. On Kubernetes, the GitHub PAT
is stored by a GitHub-scoped `credential.helper store` for compatibility with
ephemeral development pods.

## Kubernetes Jupyter Image

The root `Dockerfile` is intended for use behind an authenticated Kubernetes
ingress or proxy. It intentionally provides passwordless `sudo` and disables
Jupyter's built-in token/password authentication. Do not publish port 8888
directly to an untrusted network.

Miniforge remains available for creating user environments, while image startup
and Jupyter use the NVIDIA system Python so its bundled PyTorch/CUDA stack is not
hidden by the new conda installation.

## Directory Structure

```
setup.sh               # Installs the bootstrap environment and config files
Dockerfile              # Kubernetes Jupyter image (external auth required)

config/
├── .gitignore_global  # Global gitignore patterns
├── .tmux.conf         # tmux settings (mouse, history, colors)
└── .bashrc            # Shell settings (added to ~/.bashrc)

gpu_idle/
└── gpu_dummy.py       # Keeps GPUs busy when idle, pauses on real workloads
```
