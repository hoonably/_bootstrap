# conda
source /opt/conda/etc/profile.d/conda.sh
conda activate base

# prompt
export PS1="\[\e[0;35m\](\$(basename \$CONDA_DEFAULT_ENV))\[\e[0m\] \[\e[0;32m\]\u@\h\[\e[0m\]:\[\e[0;36m\]\w\[\e[0m\]\$ "

alias ls='ls --color=auto'
alias ll='ls -lh'
alias la='ls -A'

alias gs='git status'
alias gc='git commit -m'

alias tl='tmux ls'
alias ta='tmux attach -t'
alias tn='tmux new -s'
alias tk='tmux kill-session -t'

alias ns='nvidia-smi | grep -v Xorg'

alias claer='clear'

gpu() {
  cols=${COLUMNS:-$(tput cols 2>/dev/null || echo 120)}
  wg=3 wp=6 wu=10 wm=9
  fixed=$((wg+wp+wu+wm+12))
  w=$((cols-fixed-1)); [ $w -lt 10 ] && w=10   # <- -1 안전빵

  printf "%-*s | %-*s | %-*s | %-*s | %s\n" $wg GPU $wp PID $wu USER $wm MEM COMMAND
  printf "%*s\n" "$cols" "" | tr " " "-"

  nvidia-smi --query-compute-apps=gpu_uuid,pid,used_memory --format=csv,noheader |
  while IFS=',' read -r uuid pid mem; do
    uuid=$(echo "$uuid" | xargs); pid=$(echo "$pid" | xargs); mem=${mem% MiB}
    gpu=$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader |
          awk -F',' -v u="$uuid" '$2~u{gsub(/ /,"",$1);print $1;exit}')
    ps -p "$pid" -o user=,args= --no-headers --width "$cols" 2>/dev/null |
    awk -v wg="$wg" -v wp="$wp" -v wu="$wu" -v wm="$wm" -v w="$w" -v gpu="$gpu" -v pid="$pid" -v mem="$mem" '
      { user=$1; $1=""; cmd=substr($0,2);
        if (length(cmd)>w) cmd=substr(cmd,1,w-3)"...";
        printf "%-*s | %-*s | %-*s | %-*s | %s\n", wg,gpu, wp,pid, wu,user, wm,mem"MiB", cmd
      }'
  done
}

alias ca='conda activate'
alias cl='conda env list'
alias cr='conda env remove -n'

alias tree2='tree -a -L 2'
alias tree3='tree -a -L 3'
