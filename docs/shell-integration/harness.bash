# Harness shell integration for bash — OSC 133 semantic prompts.
#
#   Add to ~/.bashrc:   source "/path/to/harness.bash"
#
# Emits OSC 133;A to mark each prompt line and OSC 133;D;<exit> to report the previous
# command's status, so Harness can draw the prompt gutter, color success/failure, and
# jump between prompts. Only active inside a Harness terminal (the daemon exports $HARNESS).

if [ -n "$HARNESS" ] && [ "$TERM" != "dumb" ]; then
  __harness_precmd() {
    # Report the just-finished command's exit status (runs before the new prompt).
    printf '\001\033]133;D;%s\007\002' "$?"
  }
  case ";${PROMPT_COMMAND};" in
    *";__harness_precmd;"*) : ;;                                   # already installed
    *) PROMPT_COMMAND="__harness_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
  esac
  # Mark the start of the prompt itself (wrapped in \[ \] so it has zero display width).
  case "$PS1" in
    *'133;A'*) : ;;                                                # already installed
    *) PS1='\[\033]133;A\007\]'"$PS1" ;;
  esac
fi
