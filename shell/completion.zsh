# A real ZLE completion context. Request data is read, never evaluated.
# Startup files have already run because the host starts zsh with -i.
emulate -R zsh
setopt no_aliases extended_glob no_beep
autoload -Uz compinit
(( $+functions[compdef] )) || compinit -i -D
zmodload zsh/parameter

typeset -g _sg_dir=$SUGGESTIONS_DIRECTORY
typeset -g _sg_limit=${SUGGESTIONS_LIMIT:-80}
typeset -g _sg_history=${SUGGESTIONS_HISTORY:-${HISTFILE:-$HOME/.zsh_history}}
[[ -r $_sg_history ]] && builtin fc -R -- "$_sg_history" 2>/dev/null
HISTFILE=''
SAVEHIST=0
# The history parameter omits the current event. Advance past the last loaded
# entry so that the most recent real command is included as well.
builtin print -s -- "suggestions-history-boundary:$_sg_dir"
{
  typeset -i _sg_n=0
  for _sg_key in ${(Onk)history}; do
    print -rn -- "$history[$_sg_key]"$'\0'
    (( ++_sg_n >= ${SUGGESTIONS_HISTORY_LIMIT:-3000} )) && break
  done
} >| "$_sg_dir/history"
precmd_functions=()
preexec_functions=()
chpwd_functions=()
PROMPT=''
RPROMPT=''
KEYTIMEOUT=1
unsetopt menu_complete auto_menu correct correct_all
zstyle ':completion:*' menu no

function _sg_complete {
  compstate[vared]=''
  compstate[context]=command
  _main_complete
  _sg_count=$compstate[nmatches]
  compstate[list]=''
  compstate[insert]='menu:1'
}
zle -C _sg_complete complete-word _sg_complete

function _sg_request {
  local id cwd text cursor
  {
    IFS= read -r -d $'\0' id
    IFS= read -r -d $'\0' cwd
    IFS= read -r -d $'\0' text
    IFS= read -r -d $'\0' cursor
  } < "$_sg_dir/request"
  [[ $id == <-> && $cursor == <-> ]] || return
  builtin cd -q -- "$cwd" 2>/dev/null || return
  BUFFER=$text
  CURSOR=$cursor
  local -i _sg_count=0 i
  local first result
  zle _sg_complete
  {
    for (( i = 0; i < _sg_count && i < _sg_limit; ++i )); do
      result=$BUFFER
      [[ $i -gt 0 && $result == $first ]] && break
      [[ $i -eq 0 ]] && first=$result
      print -rn -- "$LBUFFER"$'\0'"$RBUFFER"$'\0'
      # Reset the numeric argument on every nested call. Without -n, ZLE
      # consumes it and subsequent calls can repeat the second candidate.
      zle .menu-complete -n 1
    done
  } >| "$_sg_dir/response"
  BUFFER=''
  CURSOR=0
  print -r -- "SUGGESTIONS:$id"
}
zle -N _sg_request
bindkey -N suggestions
bindkey -M suggestions '^[[99~' _sg_request

# vared provides ZLE without accepting shell commands. Its only binding reads
# the request file; arbitrary newlines, escapes and substitutions remain data.
print -r -- 'SUGGESTIONS:READY'
typeset _sg_buffer=''
builtin vared -M suggestions _sg_buffer
