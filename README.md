# PsiLab

A development tool for World of Warcraft: Forever. It collects facts about the game client (API answers, recipe data, window layouts, event counts) and saves them to a file, so addon code can be built on confirmed behaviour instead of assumptions. Read-only: it never changes anything in the game. The only things it sends are hidden addon messages to your group (ShadyBusiness module) and one visible chat line when you ask for it with `/lab sb say`.

## Install

With [WowUp](https://wowup.io): install from this repository's URL. Or download the `-forever.zip` from the latest release and unzip it into `_forever_/Interface/AddOns/`.

## Use

1. Log in; chat shows "PsiLab: ready".
2. Do what the module needs (for ProfitCraft: open each crafting profession once; visit a profession trainer; carry a recipe item or two).
3. `/reload` or log out. The game then writes `WTF/Account/<account>/SavedVariables/PsiLab.lua`.

Module data builds up over any number of sessions (only the error list and event counts start fresh each login), so it can be collected over several play sessions; `/lab reset <module>` starts a module over.

Commands (`/lab`, or `/psilab`):

- `/lab run`: collect everything now
- `/lab status`: what has been collected
- `/lab dump <lua expression>`: save the expression's result to the file
- `/lab reset <module>`: empty one module's data
- `/lab disable <module>`, `/lab enable <module>`: switch a module off or on; stays that way after `/reload` and logout. A module that is off collects nothing; its saved data is kept.
- `/lab settings`: the settings window: categories on the left (Modules: a checkbox per module, the same switches; Session: what has been collected, Collect now, Reload UI). The same pages are under Options > AddOns > PsiLab.

## Modules

- **ProfitCraft**: recipe API, recipe data, item stack sizes and sell prices, Auctionator's public API, profession window layout; trainer services and their tooltip data, recipe items in the bags, and recipes read with no profession window open.
- **ShadyBusiness**: whether addon chat is restricted ("chat messaging lockdown") in the open world, dungeons, combat and encounters, and whether hidden addon messages to the group still go out; group members' roles, max mana and whether it is hidden; the loot method and its change event; inspecting group members (retried every 4 seconds, recording distance, to learn the inspect range), their gear stats and talent points per tree; your own gear stats, talents and mana; whether gear-change, leader-change and ready-check events fire for group members. Group members (25) and other inspected players (100) are kept separately. Commands: `/lab sb snap` (record now), `/lab sb inspect` (inspect your target), `/lab sb say` (send one visible test line to party/raid chat).
- **Procable**: per character: Blizzard's Cooldown Manager catalogue for your class (every entry, learned or not), your spellbook and talent points per tree; your buffs and your debuffs on the target; what stays readable in combat (probed 2 seconds into every fight); your own casts with the nameplate count (for crowd control tests: cast Fear or Entangling Roots with enemy nameplates on, then off); whether the Cooldown Manager keeps updating in combat (it only counts calls, never changes it); whether the combat log's reader function exists (PsiLab never registers for the combat log: Forever blocks addons from it); the addon profiler's numbers after each fight; which slash commands use `/pro`, `/pr`, `/proc` or `/procable`. A snapshot is saved a few seconds after login; `/lab pro` saves another (out of combat).

## License

MIT, see `LICENSE`.
