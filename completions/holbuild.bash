# Bash completion for holbuild. Candidates come from `holbuild __complete`;
# when it offers none (a file argument, say), bash completes file names.

_holbuild() {
  # Split the line up to the cursor on blanks only: bash's own words break
  # `--from=THEORY` at the `=`.
  local line=${COMP_LINE:0:COMP_POINT}
  local -a words
  read -r -a words <<< "$line"
  [[ $line == *[[:blank:]] ]] && words+=("")
  local IFS=$'\n'
  COMPREPLY=($("$1" __complete "${words[@]:1}" 2>/dev/null))
  # Bash replaces only its own current word, the part after any `=`, so
  # drop what comes before it from each candidate.
  local current=${words[${#words[@]}-1]} cur=${COMP_WORDS[COMP_CWORD]}
  local before=${current%"$cur"}
  [[ -n $before && $current == *"$cur" ]] && COMPREPLY=("${COMPREPLY[@]#"$before"}")
  return 0
}

complete -o default -F _holbuild holbuild
