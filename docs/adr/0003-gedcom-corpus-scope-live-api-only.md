# GEDCOM knowledge corpus covers FH's live API, not the exported-file format

The sibling `family_historian_mobile` project supplied three docs (`fh-tag-mapping-spec.md`,
`ftf-rich-text-spec.md`, plus a developer sample `.ged` file), extensive, real-file-verified
knowledge of Family Historian's GEDCOM output. But that project parses static exported `.ged`
files, while `run_lua`'s sandbox only ever reads FH's live, resolved object model via
`fhGetTag()`/item pointers, it has no filesystem access to a `.ged` file at all (see the
Sandbox glossary entry). A large part of that spec, `_SRCT`/`_LINK_*`/`_LKID` wire mechanics,
the `_PLAC`/`_ADDR` flat gazetteer, character-encoding options, describes how data gets
serialized into a file, not something Claude will ever encounter through this bridge.

We scoped the new GEDCOM knowledge corpus to what's actually reachable live: FTF rich text
markup (which the mobile spec itself notes survives verbatim into any text field, live or
exported) and concept-level domain knowledge (Shared Facts, Fact/Record Flags, Source Template
fields, Sentence templates), cross-checked against FH's own help before being trusted, since
each was originally derived from raw-export analysis, not FH's plugin API.

The excluded exported-file-format knowledge isn't lost, it stays in the sibling project's own
docs. Revisit if this bridge ever needs to read or write a `.ged` file directly rather than only
the live in-memory project.
