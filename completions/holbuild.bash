# Bash completion for holbuild. Candidates come from `holbuild __complete`;
# when it offers none (a file argument, say), bash completes file names.

# _holbuild_dequote VAR WORD: set VAR to WORD as the shell would pass it,
# without its quotes and backslashes and with a leading `~` expanded.
# Nothing else is expanded: the line is never run.
_holbuild_dequote() {
  local in=$2 out="" quote="" c i
  [[ $in == "~" || $in == "~/"* ]] && in=$HOME${in:1}
  for ((i = 0; i < ${#in}; i++)); do
    c=${in:i:1}
    if [[ $quote == "'" ]]; then
      if [[ $c == "'" ]]; then quote=""; else out+=$c; fi
    elif [[ $c == '\' ]]; then
      i=$((i + 1))
      c=${in:i:1}
      # Inside double quotes a backslash escapes only these.
      if [[ -n $quote ]]; then
        case $c in '"' | '\' | '$' | '`') ;; *) out+='\' ;; esac
      fi
      out+=$c
    elif [[ $c == '"' ]]; then
      if [[ -n $quote ]]; then quote=""; else quote='"'; fi
    elif [[ $c == "'" && -z $quote ]]; then
      quote="'"
    else
      out+=$c
    fi
  done
  printf -v "$1" '%s' "$out"
}

_holbuild() {
  # COMP_WORDS also splits words at COMP_WORDBREAKS, `--from=THEORY` into
  # `--from`, `=` and `THEORY`, say. Join the pieces no blank separates,
  # up to the cursor, back into the words holbuild sees.
  local rest=${COMP_LINE:0:COMP_POINT} word="" before="" piece trimmed i
  local -a words=()
  for ((i = 0; i <= COMP_CWORD; i++)); do
    trimmed=${rest#"${rest%%[![:blank:]]*}"}
    if ((i > 0)) && [[ $trimmed != "$rest" ]]; then
      _holbuild_dequote piece "$word"
      words+=("$piece")
      word=""
    fi
    if ((i == COMP_CWORD)); then piece=$trimmed; else piece=${COMP_WORDS[i]}; fi
    before=$word
    word+=$piece
    rest=${trimmed#"$piece"}
  done
  _holbuild_dequote piece "$word"
  words+=("$piece")
  local IFS=$'\n'
  COMPREPLY=($("$1" __complete "${words[@]:1}" 2>/dev/null))
  # Bash replaces only its own current piece, so drop the pieces before it
  # from each candidate.
  if [[ -n $before ]]; then
    _holbuild_dequote before "$before"
    COMPREPLY=("${COMPREPLY[@]#"$before"}")
  fi
  return 0
}

complete -o default -F _holbuild holbuild
