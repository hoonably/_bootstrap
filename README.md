# _bootstrap

Lightweight setup scripts for quickly preparing a fresh server environment.
Installs basic packages, configures SSH & Git, and applies personal dotfiles automatically.

---

## 📂 Structure

```text
_bootstrap/
├── os_setup.sh             # Install system packages & Miniconda
├── bootstrap_user.sh       # Configure SSH, Git, and user environment
├── setting/
│   ├── env.sh              # Environment variables & aliases
│   ├── gitignore_global    # Global .gitignore
│   ├── tmux.conf           # tmux configuration
│   └── vimrc               # vim configuration
├── gpu_idle/
│   ├── README
│   └── gpu_idle_runner.py
└── README.md
```

---

## ⚙️ How to Use

After cloning the repository:

```bash
chmod +x os_setup.sh bootstrap_user.sh
./os_setup.sh
./bootstrap_user.sh
source ~/.bashrc
```

That’s it — your environment is ready.

---

## 🧩 Script Overview

### **os_setup.sh**

* Installs essential tools:

  * `tmux`, `tree`, `wget`, `curl`, `git`, `git-lfs`
* Installs Miniconda and runs `conda init`
* Works with or without `sudo`

### **bootstrap_user.sh**

* Creates `~/.ssh` and generates `id_ed25519` if missing
* Creates `.ssh/config` automatically
* Uploads the public key to GitHub if `GITHUB_TOKEN` is defined
* Generates `.gitconfig` automatically
* Links `setting/env.sh`, `tmux.conf`, and `vimrc` to the home directory

---

## 🧠 Notes

* The repository is fully public — only sensitive files are ignored.
* `.gitignore` excludes only private keys and certificates:

```gitignore
# private
id_ed25519
id_ed25519.pub

# common secrets
*.pem
*.key
*.p12
*.der
*.crt
```

* Scripts are idempotent (safe to re-run).
* Optionally, set your GitHub token before running to upload the SSH key automatically:

```bash
export GITHUB_TOKEN=ghp_xxxxx
```
