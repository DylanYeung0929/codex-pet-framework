claude() {
  local pet_root="${CODEX_PET_DIR:-$HOME/.claude/pet}"
  local pet="$pet_root/bin/CodexPet"
  local pet_id=""
  local show_pet=1
  [[ -t 1 ]] || show_pet=0
  local arg prev="" rid="" has_skip=0 has_continue=0
  for arg in "$@"; do
    case "$arg" in
      -p|--print|--version|-v|--help|-h) show_pet=0 ;;
      --dangerously-skip-permissions) has_skip=1 ;;
      --resume=*) rid="${arg#--resume=}" ;;
      --continue|-c) has_continue=1 ;;
    esac
    if [[ "$prev" == "--resume" || "$prev" == "-r" ]]; then rid="$arg"; fi
    prev="$arg"
  done
  # --continue resumes the newest session for this directory, whose UUID we can
  # resolve exactly; a bare --resume opens a picker we cannot pre-annotate.
  if (( has_skip == 0 )) && [[ -z "$rid" ]] && (( has_continue )); then
    local project_dir="${PWD//[^A-Za-z0-9]/-}"
    local -a transcripts
    transcripts=( "$HOME/.claude/projects/$project_dir"/*.jsonl(Nom[1]) )
    if (( ${#transcripts} > 0 )); then
      rid="${${transcripts[1]:t}:r}"
    fi
  fi
  if (( has_skip == 0 )) && [[ -n "$rid" && -f "$pet_root/review_off.txt" ]] \
     && grep -qxF -- "$rid" "$pet_root/review_off.txt"; then
    set -- "$@" --dangerously-skip-permissions
  fi
  if (( show_pet )) && [[ -x "$pet" && -z "$CODEX_PET_DISABLED" ]]; then
    pet_id="pet-$$-$RANDOM-$(date +%s)"
    mkdir -p "$pet_root/run"
    print -r -- $$ > "$pet_root/run/$pet_id.pid"
    print -r -- "${TERM_PROGRAM:-Apple_Terminal}|${TTY:-}" > "$pet_root/run/$pet_id.term"
    print -r -- 1 > "$pet_root/run/$pet_id.restartable"
    "$pet" >/dev/null 2>&1 &!
  fi
  local rc=0
  if [[ -n "$pet_id" ]]; then
    (
      export CODEX_PET_ID="$pet_id"
      while :; do
        command claude "$@"
        rc=$?
        local restart="$pet_root/run/$pet_id.restart"
        [[ -f "$restart" ]] || break
        local r_resume="" r_effort="" r_model="" r_skip=0
        local r_key r_value
        while IFS='=' read -r r_key r_value; do
          case "$r_key" in
            resume) r_resume="$r_value" ;;
            effort) r_effort="$r_value" ;;
            model) r_model="$r_value" ;;
            skip) r_skip="$r_value" ;;
          esac
        done < "$restart"
        rm -f "$restart"
        [[ "$r_resume" =~ ^[A-Za-z0-9-]+$ ]] || break
        set -- --resume "$r_resume"
        [[ -n "$r_model" ]] && set -- "$@" --model "$r_model"
        [[ -n "$r_effort" ]] && set -- "$@" --effort "$r_effort"
        (( r_skip == 1 )) && set -- "$@" --dangerously-skip-permissions
      done
      return $rc
    )
    rc=$?
    rm -f "$pet_root/run/$pet_id.json" "$pet_root/run/$pet_id.pid" "$pet_root/run/$pet_id.term" "$pet_root/run/$pet_id.restartable"
  else
    command claude "$@"
    rc=$?
  fi
  return $rc
}
