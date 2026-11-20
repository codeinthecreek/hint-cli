# .bash_aliases

if [ -x /usr/bin/dircolors ]; then
	alias ls='ls --color=auto'
fi

# safety aliases
alias rmi='rm -i'
alias mvi='mv -i'
#alias cpi='cp -i'

# history aliases
alias hgrep='history | grep'
alias hsync='history -a; history -n' hless='history | less'

[ -x /usr/bin/trash ] && alias del='/usr/bin/trash' # move to the trash, not rm
alias tarls="tar -tzf"
