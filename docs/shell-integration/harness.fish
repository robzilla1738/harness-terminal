# Harness shell integration for fish — OSC 133 semantic prompts.
#
#   Add to ~/.config/fish/config.fish:   source /path/to/harness.fish
#
# Emits OSC 133;A to mark each prompt line and OSC 133;D;<exit> to report the previous
# command's status, so Harness can draw the prompt gutter, color success/failure, and
# jump between prompts. Only active inside a Harness terminal (the daemon exports $HARNESS).

# Interactive only: `exit` in a sourced file skips the rest of the file, so scripts
# and `fish -c` never register the hooks.
status is-interactive; or exit

if set -q HARNESS; and test "$TERM" != dumb
    function __harness_osc133_prompt --on-event fish_prompt
        printf '\033]133;A\007'
    end
    function __harness_osc133_postexec --on-event fish_postexec
        printf '\033]133;D;%s\007' $status
    end
end
