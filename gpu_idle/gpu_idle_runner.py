# gpu_idle_runner.py

import subprocess, time, os, sys, argparse, datetime as dt
from typing import Dict, Optional, List, Tuple

# ===== 기본 설정 =====
POLL_INTERVAL_SEC = 5              # nvidia-smi 폴링 주기 (초)
IDLE_THRESHOLD_SEC = 55 * 60       # 유휴 임계값 기본 59분
FIRST_IDLE_MIN_DEFAULT = 1         # 첫 트리거만 1분 유휴로 단축 (옵션으로 변경 가능)
WORKER_MINUTES = 5                 # 워커 기본 부하 시간 (분)
NVIDIA_SMI = "nvidia-smi"

AGG_EVERY_SEC = 5                  # 집계 출력 주기 (모든 GPU 정보 모아서)

# --- 대시보드 렌더 유틸 ---
_prev_lines = 0

def _render_dashboard(lines: List[str]) -> None:
    """터미널에 lines를 같은 위치에 덮어쓰기"""
    use_tty = sys.stdout.isatty()
    global _prev_lines
    if use_tty and _prev_lines > 0:
        for _ in range(_prev_lines):
            sys.stdout.write("\x1b[1A")  # 커서 한 줄 위로
            sys.stdout.write("\x1b[2K")  # 해당 줄 지우기
    sys.stdout.write("\n".join(lines) + "\n")
    sys.stdout.flush()
    _prev_lines = len(lines)


def now() -> str:
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

# ===== 공통 유틸 =====
def read_gpu_utils() -> List[Tuple[int, int]]:
    """각 GPU index, utilization.gpu% 반환"""
    cmd = [
        NVIDIA_SMI,
        "--query-gpu=index,utilization.gpu",
        "--format=csv,noheader,nounits",
    ]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        raise RuntimeError(res.stderr.strip() or "failed to run nvidia-smi")
    out: List[Tuple[int, int]] = []
    for line in (l.strip() for l in res.stdout.splitlines() if l.strip()):
        parts = [p.strip() for p in line.split(",")]
        if len(parts) != 2:
            continue
        try:
            out.append((int(parts[0]), int(parts[1])))
        except ValueError:
            pass
    return out

def fmt_eta(seconds: int) -> str:
    if seconds <= 0:
        return "now"
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    return f"{h:02d}:{m:02d}:{s:02d}"

# ===== 워커 모드 =====
def run_worker(gpu_id: int, minutes: int) -> int:
    """지정 GPU에 더미 부하, torch 필요. 에러만 출력하고 진행 로그는 모두 비활성."""
    # 프로세스 타이틀 변경 시도(선택적)
    try:
        import setproctitle
        setproctitle.setproctitle(f"VLLM-[GPU{gpu_id}]")
    except Exception:
        try:
            import ctypes
            PR_SET_NAME = 15
            name = f"VLLM-{gpu_id}"[:15].encode("utf-8")
            libc = ctypes.CDLL("libc.so.6")
            libc.prctl(PR_SET_NAME, ctypes.c_char_p(name), 0, 0, 0)
        except Exception:
            pass

    try:
        import torch, torch.nn as nn, time as _t
    except Exception as e:
        print(f"[{now()}] [GPU{gpu_id}] torch import 실패: {e}")
        return 2

    if not torch.cuda.is_available():
        print(f"[{now()}] [GPU{gpu_id}] CUDA 사용 불가 상태")
        return 3

    if gpu_id >= torch.cuda.device_count():
        print(f"[{now()}] [GPU{gpu_id}] 범위 초과")
        return 4

    device = torch.device(f"cuda:{gpu_id}")
    torch.cuda.set_device(gpu_id)

    # 부하 모델(적당한 연산 부하)
    model = nn.Sequential(
        nn.Conv2d(128, 256, 3, padding=1), nn.ReLU(),
        nn.Conv2d(256, 256, 3, padding=1), nn.ReLU(),
        nn.Conv2d(256, 128, 3, padding=1), nn.AdaptiveAvgPool2d(1),
        nn.Flatten(), nn.Linear(128, 64)
    ).to(device)

    data = torch.randn(32, 128, 128, 128, device=device)
    end_t = _t.time() + minutes * 60  # 분→초

    try:
        while _t.time() < end_t:
            with torch.no_grad():
                _ = model(data)
    except KeyboardInterrupt:
        # 조용히 종료
        pass
    finally:
        try:
            torch.cuda.synchronize()
        except Exception:
            pass
        torch.cuda.empty_cache()
    return 0

# ===== 모니터 모드 =====
def run_monitor(poll: int, idle_sec: int, worker_minutes: int, first_idle_sec: Optional[int]) -> int:
    print(f"[{now()}] 모니터 시작 poll={poll}s idle={idle_sec//60}분 worker={worker_minutes}분"
          + (f" (첫 트리거 {first_idle_sec//60}분)" if first_idle_sec else ""))

    # 상태 맵
    idle_start: Dict[int, Optional[float]] = {}
    running: Dict[int, Optional[subprocess.Popen]] = {}
    first_done: Dict[int, bool] = {}
    worker_start: Dict[int, Optional[float]] = {}
    worker_dur: Dict[int, int] = {}  # 초 단위
    last_util: Dict[int, int] = {}

    # 초기 GPU 채워 넣기
    try:
        detected = read_gpu_utils()
        for idx, util in detected:
            idle_start[idx] = None
            running[idx] = None
            first_done[idx] = False
            worker_start[idx] = None
            worker_dur[idx] = 0
            last_util[idx] = util
        if not idle_start:
            print(f"[{now()}] GPU 미검출")
            return 1
        print(f"[{now()}] 감지 GPU={sorted(idle_start.keys())}", flush=True)
    except Exception as e:
        print(f"[{now()}] nvidia-smi 실패: {e}")
        return 1

    pybin = sys.executable  # 현재 인터프리터 재사용
    last_agg = 0.0

    while True:
        # 자식 종료 감시
        for idx, proc in list(running.items()):
            if proc is not None:
                rc = proc.poll()
                if rc is not None:
                    running[idx] = None
                    worker_start[idx] = None
                    worker_dur[idx] = 0

        # util 읽기
        try:
            utils = read_gpu_utils()
            # 최신 util 저장
            for idx, util in utils:
                last_util[idx] = util
                if util != 0:
                    # 유휴 종료
                    idle_start[idx] = None
        except Exception:
            # 에러 시에도 집계 출력은 유지
            pass

        t = time.time()

        # 유휴 누적/트리거 판정
        for idx in list(last_util.keys()):
            util = last_util[idx]
            if util == 0:
                if idle_start[idx] is None:
                    idle_start[idx] = t
                idle_elapsed = t - (idle_start[idx] or t)

                busy = running[idx] is not None
                threshold = idle_sec if (first_done[idx] or not first_idle_sec) else first_idle_sec

                if (idle_elapsed >= (threshold or idle_sec)) and (not busy):
                    # 워커 실행(무소음)
                    cmd = [pybin, os.path.abspath(__file__), "--worker", "--gpu-id", str(idx), "--minutes", str(worker_minutes)]
                    try:
                        env = os.environ.copy()
                        # 조용 모드 보장(워커는 에러 외 출력 없음)
                        env["QUIET_WORKER"] = "1"
                        proc = subprocess.Popen(cmd, env=env)
                        running[idx] = proc
                        first_done[idx] = True
                        worker_start[idx] = t
                        worker_dur[idx] = worker_minutes * 60
                    except Exception:
                        # 실행 실패는 집계 라인에 ERR로 표기될 수 있도록 상태만 유지
                        running[idx] = None

        # === 5초마다 집계 출력 ===
        if t - last_agg >= AGG_EVERY_SEC:
            lines = [f"[{now()}]"]
            for idx in sorted(last_util.keys()):
                util = last_util[idx]
                busy = running[idx] is not None

                if busy and worker_start[idx] is not None:
                    rem = max(0, int(worker_start[idx] + worker_dur[idx] - t))
                    pid = running[idx].pid if running[idx] else -1
                    lines.append(f"[GPU{idx}] VLLM pid={pid} util={util}% rem={fmt_eta(rem)}")
                else:
                    if util == 0:
                        idle_elapsed = int(t - (idle_start[idx] or t)) if idle_start[idx] else 0
                        th = int((idle_sec if (first_done[idx] or not first_idle_sec) else first_idle_sec) or idle_sec)
                        lines.append(f"[GPU{idx}] Waiting {idle_elapsed}s / {th}s")
                    else:
                        lines.append(f"[GPU{idx}] Using util={util}%")

            _render_dashboard(lines)
            last_agg = t


        time.sleep(POLL_INTERVAL_SEC)

# ===== 엔트리 포인트 =====
def main():
    parser = argparse.ArgumentParser(description="GPU idle 감시 → 더미 부하 실행(집계 출력 5초 간격, 쿨다운 없음)")
    parser.add_argument("--monitor", action="store_true", help="모니터 모드 강제")
    parser.add_argument("--worker", action="store_true", help="워커 모드")
    parser.add_argument("--gpu-id", type=int, default=0, help="워커 대상 GPU")
    parser.add_argument("--minutes", type=int, default=WORKER_MINUTES, help="워커 부하 시간(분)")
    parser.add_argument("--poll-sec", type=int, default=POLL_INTERVAL_SEC, help="폴링 주기(초)")
    parser.add_argument("--idle-min", type=int, default=IDLE_THRESHOLD_SEC // 60, help="유휴 임계값(분)")
    parser.add_argument("--cooldown-min", type=int, default=0, help="쿨다운(분, 무시됨)")
    parser.add_argument("--first-idle-min", type=int, default=FIRST_IDLE_MIN_DEFAULT, help="첫 트리거만 단축 유휴 임계값(분, 0이면 비활성)")
    args = parser.parse_args()

    if args.worker:
        rc = run_worker(args.gpu_id, args.minutes)
        sys.exit(rc)

    idle_sec = args.idle_min * 60
    first_idle = args.first_idle_min * 60 if args.first_idle_min and args.first_idle_min > 0 else None
    rc = run_monitor(args.poll_sec, idle_sec, args.minutes, first_idle)
    sys.exit(rc)

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print(f"[{now()}] 종료 신호 수신")
        print()