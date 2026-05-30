# Harness shell integration for zsh — OSC 133 semantic prompts.
#
#   Add to ~/.zshrc:   source "/path/to/harness.zsh"
#
# Emits OSC 133;A to mark each prompt line and OSC 133;D;<exit> to report the previous
# command's status, so Harness can draw the prompt gutter, color success/failure, and
# jump between prompts. Only active inside a Harness terminal (the daemon exports $HARNESS).

if [[ -n "$HARNESS" && "$TERM" != "dumb" ]]; then
  autoload -Uz add-zsh-hook 2>/dev/null
  __harness_precmd() {
    # Runs before each prompt: report the previous command's exit, then mark the new prompt.
    printf '\033]133;D;%s\007' "$?"
    printf '\033]133;A\007'
  }
  if (( ${+functions[add-zsh-hook]} )); then
    add-zsh-hook precmd __harness_precmd
  else
    precmd_functions+=(__harness_precmd)
  fi
fi
