# Shell integration

Séance can follow a shell directory without integration when the shell emits
OSC 7 or a conventional Bash title. The optional setup below also marks an
idle prompt, which enables **Open terminal here** without guessing whether text
is already waiting on the command line.

Séance never installs or executes these hooks remotely. Review the snippet for
your shell, add it to the interactive startup file yourself, and reconnect.

## Bash

Add to `~/.bashrc`:

```bash
if [[ $- == *i* ]] && [[ -z ${SEANCE_SHELL_INTEGRATION-} ]]; then
  SEANCE_SHELL_INTEGRATION=1
  printf '\e]1337;ShellIntegrationVersion=1;bash\a'

  __seance_prompt_start() {
    local status=$?
    printf '\e]133;D;%d\a\e]133;A\a' "$status"
    return "$status"
  }
  PROMPT_COMMAND="__seance_prompt_start${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
  PS1="${PS1}"$'\[\e]133;B\a\]'
fi
```

## Zsh

Add to `~/.zshrc`:

```zsh
if [[ -o interactive && -z ${SEANCE_SHELL_INTEGRATION-} ]]; then
  typeset -g SEANCE_SHELL_INTEGRATION=1
  printf '\e]1337;ShellIntegrationVersion=1;zsh\a'
  autoload -Uz add-zsh-hook
  __seance_precmd() {
    local status=$?
    printf '\e]133;D;%d\a\e]133;A\a' "$status"
  }
  add-zsh-hook precmd __seance_precmd
  PROMPT="${PROMPT}"$'%{\e]133;B\a%}'
fi
```

## Fish

Fish prompt functions receive transient/final-rendering calls and expose the
previous status through function-local state. A generic wrapper can therefore
break a customized prompt or emit a false idle marker immediately before a
command runs. Séance does not recommend an untested one-size-fits-all snippet.

If your fish prompt framework supports shell integration, configure it to emit
the protocol below and identify itself once per interactive shell with:

```fish
printf '\e]1337;ShellIntegrationVersion=1;fish\a'
```

The `B` marker must not be emitted for `fish_prompt --final-rendering`.

The snippets preserve the existing prompt and do not submit commands. They use
OSC 133 `A`, `B`, and `D` markers plus a narrow OSC 1337 shell identity marker.
Séance treats all remote control sequences as untrusted UX metadata: generated
paths are still validated and shell-quoted, the command is inserted without a
newline, and the user must press Enter.

Prompt frameworks may already emit OSC 133. Avoid installing two integrations
that both wrap the prompt. tmux and screen must be configured to pass OSC
sequences through; otherwise **Copy remote path** remains the safe fallback.

To uninstall, remove the added block and start a fresh shell.
