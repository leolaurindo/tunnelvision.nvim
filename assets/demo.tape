# Run `vhs assets/demo.tape` from the repository root.
# Requires Neovim, a Lua Tree-sitter parser, and optionally tokyonight.nvim.
# Number keys only show titles. All activation, search, and movement is real input.
Output assets/demo.gif
Set Shell bash
Set FontSize 20
Set Width 1100
Set Height 720
Set Padding 16
Set Theme "Catppuccin Mocha"
Set TypingSpeed 40ms
Hide
Type "nvim -u assets/demo.lua -i NONE"
Enter
Sleep 1s
Type "1"
Show
Sleep 1s
Type "/subtotal"
Enter
Sleep 700ms
Type ":TunnelVision on"
Sleep 1500ms
Enter
Type "1"
Sleep 2500ms
Type "n"
Sleep 1s
Type "n"
Sleep 1s

# Ordinary add inherits the same style as on.
Type "/discount"
Enter
Type "2"
Sleep 1s
Type ":TunnelVision add"
Sleep 1500ms
Enter
Type "2"
Sleep 3s

# Custom colors are selected explicitly, not generated per activation.
Type "/shipping"
Enter
Type "3"
Sleep 1s
Type ":lua tv.add({ highlights = pink })"
Sleep 1500ms
Enter
Type "3"
Sleep 2500ms
Type "/discount"
Enter
Type ":lua tv.add({ highlights = green })"
Sleep 1500ms
Enter
Type "3"
Sleep 3s

# First show dynamic retargeting across three symbols, with no pins.
Type "gg"
Type "/subtotal"
Enter
Type "4"
Sleep 1s
Type ":TunnelVision mode dynamic"
Sleep 1500ms
Enter
Type "4"
Sleep 1500ms
Type "j"
Type "4"
Sleep 1500ms
Type "j"
Type "4"
Sleep 1500ms
Type "k"
Type "4"
Sleep 1500ms

# Pin discount once, then keep moving through shipping, subtotal, and tax.
Type ":lua tv.pin()"
Sleep 1500ms
Enter
Type "9"
Sleep 2s
Type "j"
Type "9"
Sleep 1500ms
Type "kk"
Type "9"
Sleep 1500ms
Type "n"
Type "9"
Sleep 1s
Type "jjw"
Type "9"
Sleep 2s

Type "gg"
Type "/subtotal"
Enter
Type "5"
Sleep 1s
Type ":lua tv.on({ dim = 'none', highlights = { symbol = green.symbol } })"
Sleep 1500ms
Enter
Type "5"
Sleep 3s

Type "/\<total\>"
Enter
Type "6"
Sleep 1s
Type ":lua tv.on({ highlights = heads })"
Sleep 1500ms
Enter
Type "6"
Sleep 3s
Type "n"
Type "6"
Sleep 1s

# A separate assignment chain makes static flow expansion easier to see.
Type ":edit assets/flow.lua"
Sleep 1500ms
Enter
Type "7"
Sleep 2s
Type "/alpha"
Enter
Sleep 700ms
Type ":TunnelVision mode flow"
Sleep 1500ms
Enter
Type "7"
Sleep 3s
Type "j"
Type "7"
Sleep 1500ms
Type "j"
Type "7"
Sleep 1500ms
Type "j"
Type "7"
Sleep 2s
Type ":TunnelVision off"
Sleep 1500ms
Enter
Type "8"
Sleep 1500ms
Hide
Type ":qa!"
Enter
