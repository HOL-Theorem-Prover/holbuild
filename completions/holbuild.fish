# Fish completion for holbuild. Candidates come from `holbuild __complete`;
# when it offers none (a file argument, say), fish completes file names.

function __holbuild_complete
    set -l words (commandline -opc)
    set -l current (commandline -ct)
    set -l candidates (command $words[1] __complete $words[2..-1] "$current" 2>/dev/null)
    if set -q candidates[1]
        printf '%s\n' $candidates
    else
        __fish_complete_path "$current"
    end
end

complete -c holbuild -f -a '(__holbuild_complete)'
