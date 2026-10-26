" Bounded native syntax; avoid Markdown's HTML parser and language injections.
if exists('b:current_syntax')
  finish
endif
syntax match markdownH1 /^ \{0,3}#\{1,6}\s.*/ contains=markdownBold,markdownItalic,markdownCode
syntax match markdownListMarker /^\s*[-+*]\ze\s/
syntax match markdownOrderedListMarker /^\s*\d\+[.)]\ze\s/
syntax match markdownLinkDelimiter /|/
syntax match markdownRule /^\s*|\=\s*:\=-\{3,}:\=\s*\%(|\s*:\=-\{3,}:\=\s*\)\+|\=\s*$/
syntax region markdownItalic start=/\*\ze\S/ end=/\S\zs\*/ oneline
syntax region markdownBold start=/\*\*\ze\S/ end=/\S\zs\*\*/ oneline contains=markdownCode
syntax region markdownItalic start=/\w\@<!_\ze\S/ end=/\S\zs_\w\@!/ oneline
syntax region markdownBold start=/__\ze\S/ end=/\S\zs__/ oneline contains=markdownCode
syntax region markdownCode start=/`/ end=/`/ oneline
syntax region markdownCodeBlock matchgroup=markdownCodeDelimiter start=/^\s*\z(`\{3,\}\).*$/ end=/^\s*\z1\s*$/ keepend
syntax region markdownCodeBlock matchgroup=markdownCodeDelimiter start=/^\s*\z(\~\{3,\}\).*$/ end=/^\s*\z1\s*$/ keepend
highlight default link markdownH1 Title
highlight default link markdownListMarker Special
highlight default link markdownOrderedListMarker Special
highlight default link markdownLinkDelimiter Delimiter
highlight default link markdownRule Delimiter
highlight default link markdownItalic @markup.italic
highlight default link markdownBold @markup.strong
highlight default link markdownCode String
highlight default link markdownCodeBlock String
highlight default link markdownCodeDelimiter Delimiter
setlocal synmaxcol=300
syntax sync minlines=50 maxlines=200
let b:current_syntax = 'AgenticChat'
