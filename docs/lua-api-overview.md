# Family Historian Lua API: fhUtils, fhFileUtils, fhSQL

Three optional Lua modules ship alongside Family Historian's plugin engine.
None are loaded by default — each must be `require`'d before use. This page
is a map of what's in them; full function-by-function docs live at the
pluginstore links below.

## fhUtils — general plugin helper library

The largest of the three modules. Originally built to make Source-driven
Data Entry plugins easier to write, but used throughout general-purpose
plugins too. Covers:

## fhFileUtils — Unicode-safe file/folder I/O

Standard Lua `lfs`/`io` don't handle Unicode file names reliably on
Windows; this module is the workaround. 

## fhSQL — SQL database access

A thin, small module for talking to SQL databases from a plugin —
OLEDB connection strings or SQLite directly:
