# GPU Idle Runner

Automatically keeps GPUs running dummy workload when idle, stops when you need them.

## ⚠️ Before You Run

Install `setproctitle` in the same Python/conda environment that will run `gpu_dummy.py`.
This is not part of the top-level `_bootstrap/setup.sh`.

## 🚀 Quick Start

```bash
python -m pip install setproctitle
cd gpu_idle
tmux new -s dummy "python gpu_dummy.py"
```

Detach: `Ctrl+b` then `d`

### Check Status

```bash
tmux attach -t dummy
```

Detach: `Ctrl+b` then `d`

## 💡 How It Works

- **Auto Start**: Runs dummy load on all GPUs by default
- **Auto Stop**: Detects non-dummy processes and stops immediately
- **Auto Resume**: After 5 minutes idle, restarts dummy load
- **Note**: `nvidia-smi --query-compute-apps`는 시작 직후 2~6초 동안 비어 보일 수 있음

## ⚙️ Configuration

Edit `IDLE_THRESHOLD_SEC` in `gpu_dummy.py`:

```python
IDLE_THRESHOLD_SEC = 5 * 60  # 5 minutes
```
