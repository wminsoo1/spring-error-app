#!/usr/bin/env bash
# RQ2 실험: 서버 3 × 전략 3 × 정상·장애를 조합마다 1회 배포하고 결과를 CSV로 남긴다.
#
#   ./run.sh all                              18개 조합 (results.csv에 이미 있는 조합은 건너뜀)
#   ./run.sh one <server> <strategy> <kind>   조합 하나만 다시  예) ./run.sh one model rolling fault
#   ./run.sh restore                          Argo CD를 main 브랜치 · 실배포 값으로 되돌림
#
#   server: test | model | prod    strategy: rolling | bluegreen | canary    kind: normal | fault
#
# 배포 커밋은 experiment 브랜치(~/repos/exp-app)에만 쌓인다. main은 그대로다.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
MAIN=$(cd "$HERE/.." && pwd)                    # spring-error-app (main)
EXP=$HOME/repos/exp-app                         # experiment 브랜치 작업 폴더 (git worktree)
PLAT=$HOME/repos/gitops-platform
NS=member-a                                     # 네임스페이스이자 Argo CD 앱 이름
APP=spring-error-app
VALUES=$EXP/deploy/chart/values.yaml
OUT=$HERE/results
CSV=${RESULTS:-$OUT/results.csv}                # 다시 잴 때는 RESULTS=results/rerun.csv 처럼 따로
TIMEOUT=1200                                    # 1회 최대 20분 (모델 롤링 장애가 약 9분)

declare -A RPS=([test]=5 [model]=10 [prod]=50)
declare -A REPLICAS=([test]=2 [model]=2 [prod]=5)
declare -A DELAY=([test]=0 [model]=120 [prod]=0)   # values-<서버>.yaml의 startDelaySeconds

log() { echo "[$(date +%T)] $*" >&2; }
now() { date +%s; }

# ---------------------------------------------------------------- Git
setup_branch() {
  if [ ! -d "$EXP" ]; then
    git -C "$MAIN" fetch -q origin
    if git -C "$MAIN" ls-remote --exit-code --heads origin experiment >/dev/null 2>&1; then
      git -C "$MAIN" worktree add -q -B experiment "$EXP" origin/experiment
    else
      git -C "$MAIN" worktree add -q -b experiment "$EXP" origin/main
      git -C "$EXP" push -q -u origin experiment
    fi
    log "experiment 브랜치 준비: $EXP"
  fi
  git -C "$EXP" pull -q --rebase origin experiment
}

push_exp() {  # $1 커밋 메시지. push한 시각(epoch)을 출력
  git -C "$EXP" commit -qam "$1" || return 1
  git -C "$EXP" push -q origin experiment \
    || { git -C "$EXP" pull -q --rebase origin experiment && git -C "$EXP" push -q origin experiment; } || return 1
  now
}

set_val() {  # values.yaml의 값 하나를 바꾼다 (줄 끝 주석은 남김)
  case $1 in
    strategy)   sed -i "s/^strategy: [a-z]*/strategy: $2/" "$VALUES" ;;
    errorRate)  sed -i "s/^errorRate: \"[^\"]*\"/errorRate: \"$2\"/" "$VALUES" ;;
    appVersion) sed -i "s/^appVersion: [^ ]*/appVersion: $2/" "$VALUES" ;;
  esac
}
get_val() { grep -oP "^$1: \"?\K[^\" ]+" "$VALUES"; }

set_platform() {  # $1 브랜치(experiment|main) $2 서버(test|model|prod)
  local f=$PLAT/platform/apps/members.yaml
  git -C "$PLAT" pull -q --rebase
  sed -i "s/^\(\s*revision:\) .*/\1 $1/; s/^\(\s*valueFile:\) values-[a-z]*\.yaml/\1 values-$2.yaml/" "$f"
  if ! git -C "$PLAT" diff --quiet; then
    git -C "$PLAT" commit -qam "experiment: member-a revision=$1 server=$2" && git -C "$PLAT" push -q
  fi
  kubectl annotate application platform-root -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null
}

# ---------------------------------------------------------------- 클러스터 상태
refresh()   { kubectl annotate application $NS -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null; }
app()       { kubectl get application $NS -n argocd -o jsonpath="$1"; }
ro()        { kubectl get rollout $APP -n $NS -o jsonpath="$1"; }
app_synced(){ [ "$(app '{.status.sync.status}')" = Synced ]; }

wait_app_spec() {  # ApplicationSet 변경이 member-a 앱에 들어갈 때까지
  local i
  for i in $(seq 1 90); do
    [ "$(app '{.spec.source.helm.valueFiles[0]}')" = "values-$2.yaml" ] && \
    [ "$(app '{.spec.source.targetRevision}')" = "$1" ] && return 0
    kubectl annotate application platform-root -n argocd argocd.argoproj.io/refresh=normal --overwrite >/dev/null
    sleep 2
  done
  return 1
}

wait_server_spec() {  # $1 서버. Rollout의 Pod 수와 시작 대기가 그 서버 값이 될 때까지
  local i d
  for i in $(seq 1 90); do
    d=$(ro '{.spec.template.spec.containers[0].env[?(@.name=="START_DELAY_SECONDS")].value}')
    [ "$(ro '{.spec.replicas}')" = "${REPLICAS[$1]}" ] && [ "$d" = "${DELAY[$1]}" ] && return 0
    refresh; sleep 2
  done
  return 1
}

wait_synced() {  # Argo CD가 지금 커밋을 반영할 때까지
  local sha i; sha=$(git -C "$EXP" rev-parse HEAD)
  for i in $(seq 1 60); do
    [ "$(app '{.status.sync.revision}')" = "$sha" ] && app_synced && return 0
    refresh; sleep 2
  done
  return 1
}

is_healthy() {  # 새 버전으로 완전히 넘어감
  [ "$(ro '{.status.phase}')" = Healthy ] && \
  [ "$(ro '{.status.currentPodHash}')" = "$(ro '{.status.stableRS}')" ] && \
  [ "$(ro '{.status.observedGeneration}')" = "$(ro '{.metadata.generation}')" ]
}

is_rolled_back() {  # $1 전략. 중단됐고 사용자 요청이 모두 옛 버전 Pod로 가는 상태
  [ "$(ro '{.status.phase}')" = Degraded ] || return 1
  local stable want ready
  stable=$(ro '{.status.stableRS}'); want=$(ro '{.spec.replicas}')
  ready=$(kubectl get pods -n $NS -l "app=$APP,rollouts-pod-template-hash=$stable" \
          -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true)
  [ "$ready" -ge "$want" ] || return 1
  if [ "$1" = bluegreen ]; then
    # 블루그린: active Service가 옛 버전을 가리키면 사용자는 옛 버전만 씀 (새 Pod는 30초 뒤 정리)
    [ "$(kubectl get svc $APP -n $NS -o jsonpath='{.spec.selector.rollouts-pod-template-hash}')" = "$stable" ]
  else
    # 롤링·카나리: 기본 Service가 모든 Pod를 가리키므로 "종료 중이 아닌" 새 버전 Pod가 없어야 함
    # 종료 중인 Pod는 이미 Service에서 빠져 사용자 요청을 받지 않으므로 기다리지 않는다 (블루그린과 같은 사용자 기준)
    [ "$(kubectl get pods -n $NS -l app=$APP \
          -o jsonpath='{range .items[*]}{.metadata.labels.rollouts-pod-template-hash}{"|"}{.metadata.deletionTimestamp}{"\n"}{end}' \
          | awk -F'|' -v s="$stable" '$1 != s && $2 == ""' | wc -l)" -eq 0 ]
  fi
}

wait_healthy() {  # $1 최대 초
  local end=$(( $(now) + $1 )); sleep 5
  while [ "$(now)" -lt $end ]; do
    app_synced && is_healthy && return 0
    refresh; sleep 3
  done
  return 1
}

# ---------------------------------------------------------------- 측정
sampler() {  # $1 파일. 2초마다 "시각 Pod수(종료 중 제외) Pod수(전체) CPU(m) 메모리(Mi)"
  local act all cpu mem
  while true; do
    # 종료 중인 Pod는 deletionTimestamp가 있다. maxSurge 계산에는 들어가지 않지만 사라질 때까지 자원은 씀
    read -r act all < <(kubectl get pods -n $NS -l app=$APP \
        -o jsonpath='{range .items[*]}{.metadata.deletionTimestamp}{"|\n"}{end}' 2>/dev/null \
        | awk '{n++; if ($0 == "|") a++} END {print a+0, n+0}')
    read -r cpu mem < <(kubectl top pods -n $NS -l app=$APP --no-headers 2>/dev/null \
                        | awk '{c+=$2; m+=$3} END {print c+0, m+0}')
    echo "$(now) $act $all $cpu $mem" >> "$1"
    sleep 2
  done
}

k6_start() {  # $1 초당 요청
  kubectl delete pod k6 -n $NS --ignore-not-found --wait=true >/dev/null
  kubectl create configmap k6-script -n $NS --from-file=load.js="$HERE/load.js" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  sed "s/__RPS__/$1/" "$HERE/k6-pod.yaml" | kubectl apply -f - >/dev/null
  kubectl wait pod/k6 -n $NS --for=condition=Ready --timeout=180s >/dev/null
  sleep 10   # 부하가 자리 잡을 때까지
}
k6_stop() {  # $1 저장할 파일
  kubectl logs k6 -n $NS > "$1" 2>/dev/null
  kubectl delete pod k6 -n $NS --wait=false >/dev/null
}
k6_count() {  # $1 파일 $2 시작 $3 끝 → "요청수 실패수"
  awk -F, -v s="$2" -v e="$3" '$1=="http_req_failed" && $2>=s && $2<=e {n++; f+=$3} END {print n+0, f+0}' "$1"
}

# ---------------------------------------------------------------- 1회 실행
CUR_SERVER=""
prepare() {  # $1 서버 $2 전략. 그 조건으로 정상 상태를 만든다 (측정 안 함)
  if [ "$CUR_SERVER" != "$1" ]; then
    log "서버를 $1(으)로 바꿈"
    set_platform experiment "$1"
    wait_app_spec experiment "$1" || { log "앱 설정 반영 실패"; return 1; }
    wait_server_spec "$1" || { log "Rollout에 서버 값이 반영되지 않음"; return 1; }
    CUR_SERVER=$1
  fi
  set_val errorRate 0
  set_val strategy "$2"
  if ! git -C "$EXP" diff --quiet; then push_exp "exp: setup $1 $2" >/dev/null || return 1; fi
  wait_synced || { log "동기화 실패"; return 1; }
  wait_healthy 900 || { log "준비 상태가 Healthy가 안 됨"; return 1; }
}

run_one() {  # $1 서버 $2 전략 $3 정상|장애
  local s=$1 st=$2 k=$3 id="$1-$2-$3"
  local raw=$OUT/raw/$id; mkdir -p "$raw"; rm -f "$raw"/*
  log "===== $s · $st · $k"
  prepare "$s" "$st" || { echo "$s,$st,$k,$(date +%FT%T),,setup-failed,,,,,,,,," >> "$CSV"; return; }

  k6_start "${RPS[$s]}"
  sampler "$raw/samples.txt" & local sp=$!

  local t0 t1="" t2="" phase v
  if [ "$k" = normal ]; then
    v=$(get_val appVersion); [ "$v" = v5 ] && v=v6 || v=v5
    set_val appVersion "$v"; t0=$(push_exp "exp: $id appVersion=$v")
  else
    set_val errorRate 0.3;   t0=$(push_exp "exp: $id errorRate=0.3")
  fi
  log "   push $(date -d @"$t0" +%T)"
  wait_synced

  while [ "$(now)" -lt $((t0 + TIMEOUT)) ]; do
    phase=$(ro '{.status.phase}')
    if [ "$k" = normal ]; then
      is_healthy && { t1=$(now); break; }
      [ "$phase" = Degraded ] && { t1=$(now); break; }          # 정상 버전이 롤백됨 (오탐)
    else
      is_rolled_back "$st" && { t1=$(now); break; }
      is_healthy && { t1=$(now); break; }                       # 장애 버전이 통과함 (미탐)
    fi
    sleep 2
  done
  phase=$(ro '{.status.phase}')
  kill "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  k6_stop "$raw/k6.csv"

  if [ "$k" = fault ]; then   # Git을 정상으로 되돌리고 다시 Healthy가 될 때까지 (Git 정합성 복구)
    set_val errorRate 0; push_exp "exp: $id revert" >/dev/null; wait_synced
    wait_healthy "$TIMEOUT" && t2=$(now)
  fi

  local end=${t1:-$(now)} dur="" git_s="" reqs fails ratio maxp maxc maxm extra
  [ -n "$t1" ] && dur=$((t1 - t0)) || phase="timeout"
  [ -n "$t2" ] && git_s=$((t2 - t0))
  read -r reqs fails < <(k6_count "$raw/k6.csv" "$t0" "$end")
  ratio=$(awk -v f="$fails" -v n="$reqs" 'BEGIN {printf "%.4f", n ? f/n : 0}')
  read -r maxp maxa maxc maxm < <(awk -v s="$t0" -v e="$end" \
    '$1>=s && $1<=e {if($2>p)p=$2; if($3>a)a=$3; if($4>c)c=$4; if($5>m)m=$5} END {print p+0, a+0, c+0, m+0}' "$raw/samples.txt")
  extra=$((maxp - REPLICAS[$s]))
  echo "$s,$st,$k,$(date -d @"$t0" +%FT%T),$dur,$phase,$git_s,$reqs,$fails,$ratio,$maxp,$extra,$maxa,$maxc,$maxm" >> "$CSV"
  log "   → ${dur:-timeout}초 · $phase · 실패 $fails/$reqs ($ratio) · 최대 Pod $maxp(+$extra), 종료 중 포함 $maxa · CPU ${maxc}m · 메모리 ${maxm}Mi"
  sleep 30
}

restore() {
  log "Argo CD를 main · values-prod로 되돌림"
  set_platform main prod
  wait_app_spec main prod && wait_server_spec prod && wait_healthy 900
}

# ---------------------------------------------------------------- 시작
mkdir -p "$OUT/raw"
[ -f "$CSV" ] || echo "server,strategy,kind,pushed_at,duration_s,phase,git_restore_s,k6_reqs,k6_failed,error_ratio,max_pods,extra_pods,max_pods_all,max_cpu_m,max_mem_mi" > "$CSV"
kubectl top pods -n $NS >/dev/null 2>&1 || log "경고: kubectl top이 안 됨 (metrics-server 확인). CPU·메모리는 0으로 기록됨"

case "${1:-}" in
  all)
    setup_branch
    for s in test model prod; do
      for st in rolling bluegreen canary; do
        for k in normal fault; do
          if grep -q "^$s,$st,$k,.*,\(Healthy\|Degraded\)," "$CSV"; then log "건너뜀: $s $st $k"; continue; fi
          run_one "$s" "$st" "$k"
        done
      done
    done
    restore ;;
  one)
    [ $# -eq 4 ] || { echo "사용: $0 one <server> <strategy> <kind>"; exit 1; }
    setup_branch; run_one "$2" "$3" "$4"
    log "끝. Argo CD는 아직 experiment 브랜치를 봄 (되돌리려면 $0 restore)" ;;
  restore)
    restore ;;
  *)
    sed -n '2,10p' "$0"; exit 1 ;;
esac
