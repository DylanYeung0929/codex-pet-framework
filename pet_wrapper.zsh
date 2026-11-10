claude() {
  local pet_root="${CODEX_PET_DIR:-$HOME/.claude/pet}"
  local pet="$pet_root/bin/CodexPet"
  local pet_id=""
  local show_pet=1
  [[ -t 1 ]] || show_pet=0
  local arg prev="" rid="" has_skip=0
  for arg in "$@"; do
    case "$arg" in
      -p|--print|--version|-v|--help|-h) show_pet=0 ;;
      --dangerously-skip-permissions) has_skip=1 ;;
      --resume=*) rid="${arg#--resume=}" ;;
    esac
    if [[ "$prev" == "--resume" || "$prev" == "-r" ]]; then rid="$arg"; fi
    prev="$arg"
  done
  if (( has_skip == 0 )) && [[ -n "$rid" && -f "$pet_root/review_off.txt" ]] \
     && grep -qxF -- "$rid" "$pet_root/review_off.txt"; then
    set -- "$@" --dangerously-skip-permissions
  fi
  if (( show_pet )) && [[ -x "$pet" && -z "$CODEX_PET_DISABLED" ]]; then
    pet_id="pet-$$-$RANDOM-$(date +%s)"
    mkdir -p "$pet_root/run"
    print -r -- $$ > "$pet_root/run/$pet_id.pid"
    print -r -- "${TERM_PROGRAM:-Apple_Terminal}|${TTY:-}" > "$pet_root/run/$pet_id.term"
    "$pet" >/dev/null 2>&1 &!
  fi
  local rc=0
  if [[ -n "$pet_id" ]]; then
    ( export CODEX_PET_ID="$pet_id"; command claude "$@" )
    rc=$?
    rm -f "$pet_root/run/$pet_id.json" "$pet_root/run/$pet_id.pid" "$pet_root/run/$pet_id.term"
  else
    command claude "$@"
    rc=$?
  fi
  return $rc
}
