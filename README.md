# PsiLab

A development tool for World of Warcraft: Forever. It collects facts about the game client (API answers, recipe data, window layouts, event counts) and saves them to a file, so addon code can be built on confirmed behaviour instead of assumptions. Read-only: it never changes anything in the game.

## Install

With [WowUp](https://wowup.io): install from this repository's URL. Or download the `-forever.zip` from the latest release and unzip it into `_forever_/Interface/AddOns/`.

## Use

1. Log in; chat shows "PsiLab: ready".
2. Do what the module needs (for ProfitCraft: open each crafting profession once).
3. `/reload` or log out. The game then writes `WTF/Account/<account>/SavedVariables/PsiLab.lua`.

Commands (`/lab`, or `/psilab`):

- `/lab run`: collect everything now
- `/lab status`: what has been collected
- `/lab dump <lua expression>`: save the expression's result to the file
- `/lab reset <module>`: empty one module's data

## Modules

- **ProfitCraft**: recipe API, recipe data, item stack sizes and sell prices, Auctionator's public API, profession window layout.

## License

MIT, see `LICENSE`.
