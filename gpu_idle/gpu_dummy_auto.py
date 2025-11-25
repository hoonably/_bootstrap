#!/usr/bin/env python3
"""
GPU 더미 자동 실행기
- 기본: 모든 GPU에서 100% 더미 부하 실행
- 외부 명령으로 감지 모드 전환 (30분 연속 0%면 다시 더미 모드)
"""

import subprocess, time, os, sys, signal
from typing import Dict, List, Tuple, Optional
import datetime as dt

POLL_INTERVAL_SEC = 1
IDLE_THRESHOLD_SEC = 30 * 60  # 30분
NVIDIA_SMI = "nvidia-smi"
DASHBOARD_INTERVAL = 2  # 대시보드 업데이트 주기
CONTROL_DIR = "/tmp/gpu_dummy_control"  # 제어 파일 디렉토리

_prev_lines = 0

def _render_dashboard(lines: List[str]) -> None:
    """터미널에 lines를 같은 위치에 덮어쓰기"""
    global _prev_lines
    if sys.stdout.isatty() and _prev_lines > 0:
        for _ in range(_prev_lines):
            sys.stdout.write("\x1b[1A\x1b[2K")
    sys.stdout.write("\n".join(lines) + "\n")
    sys.stdout.flush()
    _prev_lines = len(lines)

def now() -> str:
    return dt.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

def fmt_time(seconds: int) -> str:
    if seconds <= 0:
        return "0s"
    m, s = divmod(seconds, 60)
    h, m = divmod(m, 60)
    if h > 0:
        return f"{h}h{m}m"
    elif m > 0:
        return f"{m}m{s}s"
    return f"{s}s"

def read_gpu_utils() -> List[Tuple[int, int]]:
    """각 GPU index, utilization.gpu% 반환"""
    cmd = [NVIDIA_SMI, "--query-gpu=index,utilization.gpu", "--format=csv,noheader,nounits"]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if res.returncode != 0:
        return []
    out = []
    for line in res.stdout.strip().split('\n'):
        if not line.strip():
            continue
        parts = [p.strip() for p in line.split(",")]
        if len(parts) == 2:
            try:
                out.append((int(parts[0]), int(parts[1])))
            except ValueError:
                pass
    return out

def run_dummy_worker(gpu_id: int) -> None:
    """별도 프로세스에서 지정 GPU에 더미 부하 실행"""
    # 프로세스 이름 변경
    try:
        import setproctitle
        setproctitle.setproctitle(f"Dummy-GPU{gpu_id}")
    except ImportError:
        # setproctitle 없으면 prctl 시도
        try:
            import ctypes
            libc = ctypes.CDLL("libc.so.6")
            PR_SET_NAME = 15
            name = f"Dummy-GPU{gpu_id}"[:15].encode('utf-8')
            libc.prctl(PR_SET_NAME, ctypes.c_char_p(name), 0, 0, 0)
        except Exception:
            pass
    
    try:
        import torch
        import torch.nn as nn
    except Exception:
        sys.exit(1)

    if not torch.cuda.is_available() or gpu_id >= torch.cuda.device_count():
        sys.exit(1)

    device = torch.device(f"cuda:{gpu_id}")
    torch.cuda.set_device(gpu_id)

    # 부하 모델
    model = nn.Sequential(
        nn.Conv2d(128, 256, 3, padding=1), nn.ReLU(),
        nn.Conv2d(256, 256, 3, padding=1), nn.ReLU(),
        nn.Conv2d(256, 128, 3, padding=1), nn.AdaptiveAvgPool2d(1),
        nn.Flatten(), nn.Linear(128, 64)
    ).to(device)

    data = torch.randn(32, 128, 128, 128, device=device)

    # SIGTERM 핸들러
    def handler(signum, frame):
        sys.exit(0)
    signal.signal(signal.SIGTERM, handler)

    try:
        while True:
            with torch.no_grad():
                _ = model(data)
            time.sleep(0.01)
    except KeyboardInterrupt:
        pass
    finally:
        try:
            torch.cuda.synchronize()
            torch.cuda.empty_cache()
        except Exception:
            pass

class GPUManager:
    def __init__(self):
        self.gpu_count = 0
        self.modes: Dict[int, str] = {}  # 'dummy' or 'watch'
        self.processes: Dict[int, Optional[subprocess.Popen]] = {}
        self.idle_start: Dict[int, float] = {}
        self.last_util: Dict[int, int] = {}
        
        # 제어 디렉토리 생성
        os.makedirs(CONTROL_DIR, exist_ok=True)
        
    def init_gpus(self):
        """GPU 초기화 및 더미 모드로 시작"""
        utils = read_gpu_utils()
        if not utils:
            print("GPU를 찾을 수 없습니다.")
            return False
        
        for gpu_id, _ in utils:
            self.gpu_count = max(self.gpu_count, gpu_id + 1)
            self.modes[gpu_id] = 'dummy'
            self.last_util[gpu_id] = 0
            self.idle_start[gpu_id] = 0
            self.processes[gpu_id] = None
            self.start_dummy(gpu_id)
        
        print(f"[{now()}] {self.gpu_count}개 GPU 감지, 모두 더미 모드로 시작")
        print(f"[{now()}] 외부 제어: stop <gpu_id> 스크립트 사용")
        return True
    
    def start_dummy(self, gpu_id: int):
        """더미 모드 시작 (별도 프로세스)"""
        self.stop_dummy(gpu_id)
        
        # 별도 프로세스로 워커 실행
        cmd = [sys.executable, "-c", f"""
import sys
sys.path.insert(0, '{os.path.dirname(os.path.abspath(__file__))}')
from {os.path.splitext(os.path.basename(__file__))[0]} import run_dummy_worker
run_dummy_worker({gpu_id})
"""]
        
        try:
            proc = subprocess.Popen(
                cmd,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                start_new_session=True
            )
            self.processes[gpu_id] = proc
            self.modes[gpu_id] = 'dummy'
            self.idle_start[gpu_id] = 0
        except Exception:
            self.processes[gpu_id] = None
    
    def stop_dummy(self, gpu_id: int):
        """더미 모드 중지 (프로세스 종료)"""
        if gpu_id in self.processes and self.processes[gpu_id] is not None:
            proc = self.processes[gpu_id]
            try:
                proc.terminate()
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()
            except Exception:
                pass
            self.processes[gpu_id] = None
    
    def switch_to_watch(self, gpu_id: int):
        """감지 모드로 전환"""
        if gpu_id >= self.gpu_count:
            return
        
        if self.modes.get(gpu_id) == 'watch':
            return
        
        self.stop_dummy(gpu_id)
        self.modes[gpu_id] = 'watch'
        self.idle_start[gpu_id] = 0
    
    def check_control_files(self):
        """제어 파일 확인 및 처리"""
        try:
            for filename in os.listdir(CONTROL_DIR):
                if filename.startswith("watch_"):
                    filepath = os.path.join(CONTROL_DIR, filename)
                    try:
                        gpu_id = int(filename.split("_")[1])
                        self.switch_to_watch(gpu_id)
                        os.remove(filepath)  # 처리 후 파일 삭제
                    except (ValueError, IndexError):
                        pass
        except FileNotFoundError:
            pass
    
    def update(self):
        """상태 업데이트 (감지 모드 체크)"""
        utils = read_gpu_utils()
        util_map = {idx: util for idx, util in utils}
        
        t = time.time()
        
        for gpu_id in range(self.gpu_count):
            util = util_map.get(gpu_id, 0)
            self.last_util[gpu_id] = util
            
            if self.modes.get(gpu_id) == 'watch':
                if util == 0:
                    if self.idle_start[gpu_id] == 0:
                        self.idle_start[gpu_id] = t
                    
                    idle_duration = t - self.idle_start[gpu_id]
                    if idle_duration >= IDLE_THRESHOLD_SEC:
                        # 30분 연속 0% -> 더미 모드로 복귀
                        print(f"\n[{now()}] [GPU{gpu_id}] 30분 연속 0%, 더미 모드로 복귀")
                        self.start_dummy(gpu_id)
                else:
                    # 사용 중이면 idle 카운터 초기화
                    self.idle_start[gpu_id] = 0
    
    def get_status_lines(self) -> List[str]:
        """대시보드 출력용 상태 라인"""
        lines = [f"[{now()}] GPU 더미 자동 실행기"]
        
        t = time.time()
        for gpu_id in range(self.gpu_count):
            mode = self.modes.get(gpu_id, 'unknown')
            util = self.last_util.get(gpu_id, 0)
            
            if mode == 'dummy':
                lines.append(f"  [GPU{gpu_id}] 더미 모드 실행중 (util={util}%)")
            elif mode == 'watch':
                if util == 0 and self.idle_start[gpu_id] > 0:
                    idle_dur = int(t - self.idle_start[gpu_id])
                    remain = max(0, IDLE_THRESHOLD_SEC - idle_dur)
                    lines.append(f"  [GPU{gpu_id}] 감지 모드 - 유휴 {fmt_time(idle_dur)} / {fmt_time(IDLE_THRESHOLD_SEC)} (남은시간 {fmt_time(remain)})")
                else:
                    lines.append(f"  [GPU{gpu_id}] 감지 모드 - 사용중 (util={util}%)")
        
        return lines

def main():
    # 워커 모드 체크 (내부 호출용)
    if len(sys.argv) > 1 and sys.argv[1] == '--worker':
        gpu_id = int(sys.argv[2])
        run_dummy_worker(gpu_id)
        return 0
    
    manager = GPUManager()
    
    if not manager.init_gpus():
        return 1
    
    last_dashboard = 0
    
    try:
        while True:
            manager.check_control_files()  # 제어 파일 확인
            manager.update()
            
            # 대시보드 업데이트
            if time.time() - last_dashboard >= DASHBOARD_INTERVAL:
                _render_dashboard(manager.get_status_lines())
                last_dashboard = time.time()
            
            time.sleep(POLL_INTERVAL_SEC)
    except KeyboardInterrupt:
        print(f"\n[{now()}] 종료 중...")
        for gpu_id in range(manager.gpu_count):
            manager.stop_dummy(gpu_id)
        print("종료됨")
    
    return 0

if __name__ == "__main__":
    sys.exit(main())
