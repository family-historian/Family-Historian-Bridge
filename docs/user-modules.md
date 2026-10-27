# FH MCP Bridge: Your Own Helper Modules

If there are things you want your AI assistant to do the same way every time it works on
your project, such as your house rules for how facts are entered, or the checks you run
after every change, you can keep them as small Lua files called **helper modules**. The AI
loads them when it needs them, instead of working the rules out again on every question.

You install the modules; the AI uses them. The Bridge itself never writes to them.

## When a module is worth having

- **House rules**, the conventions your project follows that FH doesn't enforce. For
  example: every place ends with its country; a woman is recorded under her maiden surname;
  an occupation is entered in the words the source uses; a baptism goes in a Baptism fact,
  never in Birth.
- **Checks**, the things you want confirmed after any change. For example: every fact has
  at least one source citation; no citation has landed on the person instead of the fact
  it supports; nobody has a death date before their birth date.

Writing a rule or a check down once means it's applied the same way every time, whichever
conversation you're in. For a one-off question you don't need a module at all. Just ask.

## Where the files go

There are two folders, and the AI looks in them in this order:

1. **This project only:** `Plugin Data\AI Connector\modules` inside your project's data
   folder, for example
   `C:\Users\you\Documents\Family Historian Projects\Smith Family\Smith Family.fh_data\Plugin Data\AI Connector\modules`.
2. **All your projects:** `Calico Pie\Family Historian 8\Plugin Data\AI Connector\modules`
   in your own Windows application data, for example
   `C:\Users\you\AppData\Roaming\Calico Pie\Family Historian 8\Plugin Data\AI Connector\modules`.
   Only your Windows account uses this one. Anyone else who signs in to the same computer
   has their own.

If both folders have a module with the same name, the project's copy is the one used. So
you can keep a general version for all your projects and override it in one.

The easiest way to find the exact paths on your computer is to ask the AI: "where do my
helper modules go?". It reads them from `describe_project`, which reports both folders
even before you've created them. Create any folder that doesn't exist yet. Windows hides
`AppData`, so type `%APPDATA%\Calico Pie\Family Historian 8\Plugin Data` into File
Explorer's address bar rather than browsing to it.

## What a module looks like

A module is one `.lua` file. Its name is what the AI asks for, so stick to letters, digits
and underscores: `house_checks.lua` works, but `house checks.lua` and `house-checks.lua`
don't.

Inside, it's ordinary Lua that ends by returning a table of functions. A small example,
saved as `house_checks.lua`:

```lua
-- Checks this project runs after any change.
local M = {}

local function hasCitation(fact)
  local child = fhNewItemPtr()
  child:MoveToFirstChildItem(fact)
  while child:IsNotNull() do
    if fhGetTag(child) == "SOUR" then return true end
    child:MoveNext()
  end
  return false
end

-- Every fact (event or attribute) on this person with no source citation,
-- e.g. { "OCCU", "RESI" }. Names and other non-fact items aren't checked here.
function M.uncitedFacts(person)
  local missing = {}
  local item = fhNewItemPtr()
  item:MoveToFirstChildItem(person)
  while item:IsNotNull() do
    if fhIsFact(item) and not hasCitation(item) then
      table.insert(missing, fhGetTag(item))
    end
    item:MoveNext()
  end
  return missing
end

M._DOC = {
  uncitedFacts = "Tags of this person's facts that have no source citation",
}

return M
```

The `_DOC` table is optional. When the AI lists your modules it sees these one-line
descriptions next to each function's name, so it knows what a module offers without opening
the file.

Save it as plain text. A UTF-8 file is fine, including one Notepad saved with a byte-order
mark. Check that Windows hasn't quietly called it `house_checks.lua.txt`: turn on **View >
File name extensions** in File Explorer if you're not sure.

## Using a module

You don't need to write any Lua yourself to use one. Just tell the AI:

> After you add anything to a person, run my house_checks module and tell me about any
> uncited facts.

The AI sees your modules at the start of a conversation (they're listed in
`describe_project`) and loads one in its script with `require("house_checks")`.

A module can load another module the same way. A set of checks can build on a set of house
rules, for instance.

## Writing or changing a module

You can write modules yourself, or ask the AI to draft one: "write me a module that checks
every place name ends with the country". The Bridge can't save it into the folder; that
step is always yours, so you read it before it's used. (If your AI tool can save files on
your computer, it can put the module in the folder for you when you ask, but it's still
your decision and your folder.)

Changes take effect straight away. The files are read fresh for every question, so there's
no need to Stop and Start the Session after editing one.

Before relying on a new module, ask the AI to try it in a **Read-only** Session first.
Anything it would change then fails harmlessly, and you can see what it does.

## What a module can and can't do

A module can do exactly what the AI's own scripts can, and no more:

- **In a Read-only Session**, its read functions work, and anything that would change
  your tree fails with nothing changed. A module that mixes the two is fine: its read
  functions still work.
- **In a Read-write Session**, the usual rules apply. Every change it makes goes in the
  Session's Research Note, and a change made without logging is undone automatically,
  exactly as it would be from the AI's own script.
- It can't read or write files, reach the internet, or show dialogs, any more than the AI's
  scripts can.
- Nothing carries over between questions. A module starts fresh every time it's loaded.
- When the AI lists your modules, it loads each one to see what it offers, so anything at
  the top level of a module (outside its functions) runs then. Keep that part to setting
  up functions and tables. Loading for the list is always done read-only. If the AI asks
  for the list from inside a script in a Read-write Session, it gets the names only, so a
  list can never change your tree.
- A module that fails to load fails only that request for it. The rest of the AI's script
  can carry on.
- Most of the safety checks that look at the AI's scripts before they run look at your
  module's text too. The one left out is the check that refuses a Read-only script for
  mentioning a function that changes the tree, so that a module of mixed read and write
  helpers can still be used for its reads.

## Troubleshooting

**"no module house_checks in … or …"**: the AI couldn't find the file in either folder. Check
the name and the `.lua` extension (see above), and that it's in one of the two folders
listed in the message.

**"module names are letters, digits and underscores only"**: rename the file, for example
from `house-checks.lua` to `house_checks.lua`.

**An error naming your module and a line number** (for example `house_checks.lua:12: …`):
the problem is inside the module at that line. Ask the AI to look at it with you.

**A module listed as not loaded**: `describe_project` gives the reason next to it, usually
an error naming the file and line. Ask the AI to show it to you.

**"requires itself"**: the module loads itself, either directly or through another module
that loads it back. Break the loop.

**Your edit doesn't seem to have taken effect**: check you edited the copy that's actually
used. If the same name is in both folders, the project's copy wins, and `describe_project`
marks the other one as **shadowed**.

**The AI doesn't mention your modules at all**: ask it to call `describe_project` and look
at `userModules`. If that section is missing, your Bridge plugin predates user modules.

## Sharing modules

- The project folder travels with the project: copy or back up the project, and its
  modules go too. Your own folder doesn't, so back it up yourself, and copy a module into
  the project folder if the project needs it wherever it goes.
- To share a module with someone else, send them the `.lua` file and ask them to read it
  before they put it in one of their folders, as they would any plugin.
