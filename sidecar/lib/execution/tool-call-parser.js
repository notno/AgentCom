'use strict';

/**
 * Tool Call Output Parser -- 3-layer extraction from Ollama response messages.
 *
 * Priority order:
 * 1. Native tool_calls field (preferred path)
 * 2. JSON extraction from content (regex for {"name":..., "arguments":...})
 * 3. XML extraction from content (Qwen3 <tool_call> fallback for >5 tools)
 *
 * Returns one of:
 * - { type: 'tool_calls', calls: [{ name, arguments }] }
 * - { type: 'final_answer', content: string }
 * - { type: 'empty', content: '' }
 */

/**
 * Integer parameter names that should be coerced from strings.
 */
const INTEGER_PARAMS = new Set([
  'start_line', 'end_line', 'timeout_ms', 'max_results'
]);

/**
 * Coerce argument types for known tool parameters.
 * Handles Qwen3 8B's tendency to return string types instead of native JSON types.
 *
 * @param {object} args - Tool arguments object
 * @returns {object} Arguments with coerced types
 */
function coerceArguments(args) {
  if (!args || typeof args !== 'object') return args || {};

  const coerced = { ...args };

  for (const [key, value] of Object.entries(coerced)) {
    if (typeof value !== 'string') continue;

    // Boolean coercion
    if (value === 'true') {
      coerced[key] = true;
      continue;
    }
    if (value === 'false') {
      coerced[key] = false;
      continue;
    }

    // Integer coercion for known params
    if (INTEGER_PARAMS.has(key)) {
      const parsed = parseInt(value, 10);
      if (!isNaN(parsed)) {
        coerced[key] = parsed;
      }
    }
  }

  return coerced;
}

/**
 * Layer 1: Extract tool calls from native tool_calls field.
 *
 * @param {object} message - Ollama response message object
 * @returns {Array|null} Array of { name, arguments } or null if no native calls
 */
function extractNativeToolCalls(message) {
  if (!message || !Array.isArray(message.tool_calls) || message.tool_calls.length === 0) {
    return null;
  }

  const calls = [];
  for (const tc of message.tool_calls) {
    if (!tc.function || !tc.function.name) continue;
    calls.push({
      name: tc.function.name,
      arguments: coerceArguments(tc.function.arguments || {})
    });
  }

  return calls.length > 0 ? calls : null;
}

/**
 * Strip Qwen3 thinking blocks from content.
 *
 * @param {string} content - Raw content string
 * @returns {string} Content with thinking blocks removed
 */
function stripThinkingBlocks(content) {
  if (!content) return '';
  return content.replace(/<think>[\s\S]*?<\/think>/g, '').trim();
}

/**
 * Layer 2: Extract tool calls from JSON patterns in content.
 *
 * @param {string} content - Message content (already stripped of thinking blocks)
 * @returns {Array|null} Array of { name, arguments } or null if no matches
 */
function extractJsonToolCalls(content) {
  if (!content) return null;

  const regex = /\{\s*"name"\s*:\s*"(\w+)"\s*,\s*"arguments"\s*:\s*(\{[^}]*\})\s*\}/g;
  const calls = [];
  let match;

  while ((match = regex.exec(content)) !== null) {
    try {
      const args = JSON.parse(match[2]);
      calls.push({
        name: match[1],
        arguments: coerceArguments(args)
      });
    } catch (e) {
      // Skip unparseable JSON
    }
  }

  return calls.length > 0 ? calls : null;
}

/**
 * Layer 3: Extract tool calls from XML <tool_call> blocks in content.
 *
 * @param {string} content - Message content (already stripped of thinking blocks)
 * @returns {Array|null} Array of { name, arguments } or null if no matches
 */
function extractXmlToolCalls(content) {
  if (!content) return null;

  const regex = /<tool_call>\s*(\{[\s\S]*?\})\s*<\/tool_call>/g;
  const calls = [];
  let match;

  while ((match = regex.exec(content)) !== null) {
    try {
      const parsed = JSON.parse(match[1]);
      if (parsed.name) {
        calls.push({
          name: parsed.name,
          arguments: coerceArguments(parsed.arguments || {})
        });
      }
    } catch (e) {
      // Skip unparseable XML blocks
    }
  }

  return calls.length > 0 ? calls : null;
}

/**
 * Parse tool calls from an Ollama response message using 3-layer extraction.
 *
 * @param {object} message - Ollama response message object
 * @returns {{ type: string, calls?: Array, content?: string }}
 */
function parseToolCalls(message) {
  if (!message) {
    return { type: 'empty', content: '' };
  }

  // Layer 1: Native tool_calls field (highest priority)
  const nativeCalls = extractNativeToolCalls(message);
  if (nativeCalls) {
    return { type: 'tool_calls', calls: nativeCalls };
  }

  // Get content for Layer 2 and 3
  const rawContent = message.content || '';
  const strippedContent = stripThinkingBlocks(rawContent);

  // Layer 2: JSON extraction from content
  const jsonCalls = extractJsonToolCalls(strippedContent);
  if (jsonCalls) {
    return { type: 'tool_calls', calls: jsonCalls };
  }

  // Layer 3: XML extraction from content
  const xmlCalls = extractXmlToolCalls(strippedContent);
  if (xmlCalls) {
    return { type: 'tool_calls', calls: xmlCalls };
  }

  // No tool calls found -- check if there's content (final answer) or empty
  if (strippedContent.length > 0) {
    return { type: 'final_answer', content: strippedContent };
  }

  return { type: 'empty', content: '' };
}

module.exports = { parseToolCalls, coerceArguments, stripThinkingBlocks };
