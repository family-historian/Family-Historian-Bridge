const MAX_ASSISTANT_NAME_LENGTH = 40;

/**
 * Normalises an AI assistant's self-reported name for the session log: control characters
 * to spaces, whitespace collapsed, trimmed, capped. Returns null when nothing usable is
 * left. The Bridge re-sanitises, but this keeps the header well-formed.
 */
export function sanitiseAssistantName(raw: string | null | undefined): string | null {
  if (!raw) return null;
  // eslint-disable-next-line no-control-regex
  const cleaned = raw.replace(/[\u0000-\u001f\u007f]/g, " ").replace(/\s+/g, " ").trim();
  if (!cleaned) return null;
  return cleaned.slice(0, MAX_ASSISTANT_NAME_LENGTH).trim();
}

/** Agent-supplied name wins; MCP `clientInfo.name` is the fallback. */
export function resolveAssistantName(
  supplied: string | null | undefined,
  clientName: string | null | undefined,
): string | null {
  return sanitiseAssistantName(supplied) ?? sanitiseAssistantName(clientName);
}
