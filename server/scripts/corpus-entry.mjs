#!/usr/bin/env node
// Dev-only helper for editing server/data/gedcom-knowledge-corpus.jsonl (schema:
// GedcomKnowledgeEntry in src/gedcomKnowledge.ts) without hand-rolled Python/jq one-liners.
// Serena's replace_content can't do this safely: a new entry has no symbol boundary to
// anchor on, and neither Serena nor a raw text edit checks id-uniqueness, JSON-validity
// of the line, or the confidence enum before it lands in the file.
//
// Usage:
//   node scripts/corpus-entry.mjs add <entry.json>   Append entry.json's object as a new line.
//   node scripts/corpus-entry.mjs get <id>            Pretty-print one entry by id.
//   node scripts/corpus-entry.mjs check               Validate the corpus file as it stands.
//
// entry.json holds one JSON object (not JSONL) with the entry's fields. `add` validates it
// against the same rules as `check`, appends it, then re-validates the whole file.
import { readFileSync, appendFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const corpusPath = join(repoRoot, "data", "gedcom-knowledge-corpus.jsonl");

const REQUIRED_FIELDS = ["id", "title", "breadcrumb", "confidence", "source", "text"];
const VALID_CONFIDENCE = ["Verified", "Confirmed", "Documented", "Likely"];

function loadLines() {
  const raw = readFileSync(corpusPath, "utf8");
  return raw.split("\n").filter((line) => line.trim().length > 0);
}

function parseEntry(line, lineNo) {
  let entry;
  try {
    entry = JSON.parse(line);
  } catch (err) {
    throw new Error(`line ${lineNo}: invalid JSON — ${err.message}`);
  }
  for (const field of REQUIRED_FIELDS) {
    if (!(field in entry)) {
      throw new Error(`line ${lineNo}: missing required field "${field}"`);
    }
  }
  if (!Array.isArray(entry.breadcrumb) || entry.breadcrumb.length === 0) {
    throw new Error(`line ${lineNo}: "breadcrumb" must be a non-empty array`);
  }
  if (!VALID_CONFIDENCE.includes(entry.confidence)) {
    throw new Error(
      `line ${lineNo}: "confidence" must be one of ${VALID_CONFIDENCE.join(", ")}, got "${entry.confidence}"`,
    );
  }
  return entry;
}

// Returns the parsed entries, or throws on the first problem found (duplicate ids reported
// together, everything else fails fast — a duplicate id is only knowable after every line
// has been read once).
function validateCorpus(lines) {
  const entries = lines.map((line, i) => parseEntry(line, i + 1));
  const seen = new Map();
  for (const entry of entries) {
    if (seen.has(entry.id)) {
      throw new Error(`duplicate id "${entry.id}" (lines ${seen.get(entry.id)} and ${entries.indexOf(entry) + 1})`);
    }
    seen.set(entry.id, entries.indexOf(entry) + 1);
  }
  return entries;
}

function cmdCheck() {
  const entries = validateCorpus(loadLines());
  console.log(`OK — ${entries.length} entries, all valid.`);
}

function cmdAdd(entryPath) {
  const lines = loadLines();
  const existing = validateCorpus(lines);

  const newEntryRaw = readFileSync(resolve(entryPath), "utf8");
  const newEntry = parseEntry(newEntryRaw, "<new entry>");

  if (existing.some((e) => e.id === newEntry.id)) {
    throw new Error(`id "${newEntry.id}" already exists in the corpus`);
  }

  // Corpus convention (see docs/adr/0011): entries sharing a breadcrumb family are matched
  // by one search_gedcom_knowledge/grep_gedcom_knowledge call, and each entry's title is
  // prefixed with that family's search term. Warn rather than block — some families don't
  // follow this (e.g. one-off entries), so it's a hint, not a rule.
  const siblingFamily = existing.filter(
    (e) => JSON.stringify(e.breadcrumb) === JSON.stringify(newEntry.breadcrumb),
  );
  if (siblingFamily.length > 0) {
    const prefix = siblingFamily[0].title.split(":")[0];
    if (!newEntry.title.startsWith(prefix + ":")) {
      console.warn(
        `warning: sibling entries in this breadcrumb use the title prefix "${prefix}:" — "${newEntry.title}" doesn't match.`,
      );
    }
  }

  appendFileSync(corpusPath, JSON.stringify(newEntry) + "\n");
  validateCorpus(loadLines()); // re-read from disk to confirm the write landed cleanly
  console.log(`Added "${newEntry.id}" — ${existing.length + 1} entries total.`);
}

function cmdGet(id) {
  const entries = validateCorpus(loadLines());
  const entry = entries.find((e) => e.id === id);
  if (!entry) {
    throw new Error(`no entry with id "${id}" (${entries.length} entries in corpus)`);
  }
  console.log(JSON.stringify(entry, null, 2));
}

const [, , cmd, arg] = process.argv;
try {
  if (cmd === "check") {
    cmdCheck();
  } else if (cmd === "add" && arg) {
    cmdAdd(arg);
  } else if (cmd === "get" && arg) {
    cmdGet(arg);
  } else {
    console.error("Usage: node scripts/corpus-entry.mjs add <entry.json> | get <id> | check");
    process.exit(1);
  }
} catch (err) {
  console.error(`Error: ${err.message}`);
  process.exit(1);
}
