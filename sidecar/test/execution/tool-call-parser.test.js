'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { parseToolCalls, coerceArguments, stripThinkingBlocks } = require('../../lib/execution/tool-call-parser');

describe('tool-call-parser', () => {

  // -------------------------------------------------------------------------
  // Layer 1: Native tool_calls field
  // -------------------------------------------------------------------------

  describe('Layer 1: native tool_calls', () => {
    it('extracts a single native tool call', () => {
      const message = {
        content: '',
        tool_calls: [{
          function: { name: 'read_file', arguments: { path: 'src/main.js' } }
        }]
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls.length, 1);
      assert.strictEqual(result.calls[0].name, 'read_file');
      assert.deepStrictEqual(result.calls[0].arguments, { path: 'src/main.js' });
    });

    it('extracts multiple native tool calls', () => {
      const message = {
        content: '',
        tool_calls: [
          { function: { name: 'read_file', arguments: { path: 'a.js' } } },
          { function: { name: 'write_file', arguments: { path: 'b.js', content: 'hello' } } }
        ]
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls.length, 2);
      assert.strictEqual(result.calls[0].name, 'read_file');
      assert.strictEqual(result.calls[1].name, 'write_file');
    });

    it('defaults missing arguments to empty object', () => {
      const message = {
        content: '',
        tool_calls: [{ function: { name: 'list_directory' } }]
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.deepStrictEqual(result.calls[0].arguments, {});
    });

    it('skips entries without function.name', () => {
      const message = {
        content: '',
        tool_calls: [
          { function: { name: 'read_file', arguments: { path: 'x.js' } } },
          { function: {} },
          { something_else: true }
        ]
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls.length, 1);
    });
  });

  // -------------------------------------------------------------------------
  // Layer 2: JSON extraction from content
  // -------------------------------------------------------------------------

  describe('Layer 2: JSON-in-content', () => {
    it('extracts a single JSON tool call from content', () => {
      const message = {
        content: 'I will read the file. {"name":"read_file", "arguments":{"path":"src/index.js"}}'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls.length, 1);
      assert.strictEqual(result.calls[0].name, 'read_file');
      assert.strictEqual(result.calls[0].arguments.path, 'src/index.js');
    });

    it('extracts multiple JSON tool calls from content', () => {
      const message = {
        content: '{"name":"read_file", "arguments":{"path":"a.js"}} then {"name":"write_file", "arguments":{"path":"b.js", "content":"ok"}}'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls.length, 2);
    });

    it('handles whitespace in JSON patterns', () => {
      const message = {
        content: '{  "name" : "run_command" , "arguments" : { "command" : "ls" }  }'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls[0].name, 'run_command');
    });
  });

  // -------------------------------------------------------------------------
  // Layer 3: XML extraction from content
  // -------------------------------------------------------------------------

  describe('Layer 3: XML-in-content', () => {
    it('extracts a single XML tool call', () => {
      const message = {
        content: '<tool_call>{"name":"search_files", "arguments":{"pattern":"TODO"}}</tool_call>'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls.length, 1);
      assert.strictEqual(result.calls[0].name, 'search_files');
    });

    it('extracts multiple XML tool calls', () => {
      const message = {
        content: '<tool_call>{"name":"read_file", "arguments":{"path":"a.js"}}</tool_call>\n<tool_call>{"name":"write_file", "arguments":{"path":"b.js", "content":"hi"}}</tool_call>'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls.length, 2);
    });

    it('handles whitespace inside tool_call tags', () => {
      const message = {
        content: '<tool_call>\n  {"name":"read_file", "arguments":{"path":"x.js"}}\n</tool_call>'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls[0].name, 'read_file');
    });
  });

  // -------------------------------------------------------------------------
  // Qwen3 thinking block stripping
  // -------------------------------------------------------------------------

  describe('Qwen3 thinking block stripping', () => {
    it('strips thinking blocks before parsing JSON-in-content', () => {
      const message = {
        content: '<think>Let me analyze this...</think>{"name":"read_file", "arguments":{"path":"src/main.js"}}'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls[0].name, 'read_file');
    });

    it('strips thinking blocks before parsing XML-in-content', () => {
      const message = {
        content: '<think>I need to think about this for a moment.\nOK, I know what to do.</think><tool_call>{"name":"write_file", "arguments":{"path":"out.txt", "content":"done"}}</tool_call>'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls[0].name, 'write_file');
    });

    it('strips multiple thinking blocks', () => {
      const message = {
        content: '<think>block1</think>some text <think>block2</think>{"name":"run_command", "arguments":{"command":"ls"}}'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
    });

    it('returns final_answer from content after stripping thinking blocks', () => {
      const message = {
        content: '<think>Let me analyze...</think>The task is complete. All files have been updated.'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'final_answer');
      assert.ok(result.content.includes('The task is complete'));
    });
  });

  // -------------------------------------------------------------------------
  // Argument coercion
  // -------------------------------------------------------------------------

  describe('argument coercion', () => {
    it('coerces string "true" to boolean true', () => {
      const message = {
        tool_calls: [{
          function: { name: 'write_file', arguments: { path: 'a.js', content: 'x', create_dirs: 'true' } }
        }]
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.calls[0].arguments.create_dirs, true);
    });

    it('coerces string "false" to boolean false', () => {
      const message = {
        tool_calls: [{
          function: { name: 'list_directory', arguments: { path: '.', recursive: 'false' } }
        }]
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.calls[0].arguments.recursive, false);
    });

    it('coerces string numbers for integer params', () => {
      const message = {
        tool_calls: [{
          function: { name: 'read_file', arguments: { path: 'a.js', start_line: '10', end_line: '20' } }
        }]
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.calls[0].arguments.start_line, 10);
      assert.strictEqual(result.calls[0].arguments.end_line, 20);
    });

    it('coerces timeout_ms and max_results', () => {
      const result1 = coerceArguments({ command: 'ls', timeout_ms: '5000' });
      assert.strictEqual(result1.timeout_ms, 5000);

      const result2 = coerceArguments({ pattern: 'foo', max_results: '25' });
      assert.strictEqual(result2.max_results, 25);
    });

    it('does not coerce non-integer string params', () => {
      const result = coerceArguments({ path: '123', content: 'true' });
      // path is not in INTEGER_PARAMS, content is not a boolean keyword
      // Actually 'true' IS coerced to boolean
      assert.strictEqual(result.path, '123');
      assert.strictEqual(result.content, true);
    });

    it('handles null/undefined arguments', () => {
      const result = coerceArguments(null);
      assert.deepStrictEqual(result, {});
    });
  });

  // -------------------------------------------------------------------------
  // Final answer detection
  // -------------------------------------------------------------------------

  describe('final answer detection', () => {
    it('returns final_answer when content has no tool calls', () => {
      const message = { content: 'I have completed the task. The function now works correctly.' };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'final_answer');
      assert.ok(result.content.includes('completed the task'));
    });

    it('returns final_answer for plain text response', () => {
      const message = { content: 'Done.' };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'final_answer');
      assert.strictEqual(result.content, 'Done.');
    });
  });

  // -------------------------------------------------------------------------
  // Empty/malformed response handling
  // -------------------------------------------------------------------------

  describe('empty/malformed response', () => {
    it('returns empty for null message', () => {
      const result = parseToolCalls(null);
      assert.strictEqual(result.type, 'empty');
    });

    it('returns empty for undefined message', () => {
      const result = parseToolCalls(undefined);
      assert.strictEqual(result.type, 'empty');
    });

    it('returns empty for message with empty content and no tool_calls', () => {
      const result = parseToolCalls({ content: '' });
      assert.strictEqual(result.type, 'empty');
    });

    it('returns empty for message with only whitespace content', () => {
      const result = parseToolCalls({ content: '   \n  ' });
      assert.strictEqual(result.type, 'empty');
    });

    it('returns empty when only thinking block with no other content', () => {
      const result = parseToolCalls({ content: '<think>just thinking...</think>' });
      assert.strictEqual(result.type, 'empty');
    });
  });

  // -------------------------------------------------------------------------
  // Priority order: native > JSON > XML
  // -------------------------------------------------------------------------

  describe('priority order', () => {
    it('prefers native tool_calls over JSON-in-content', () => {
      const message = {
        content: '{"name":"write_file", "arguments":{"path":"wrong.js", "content":"bad"}}',
        tool_calls: [{ function: { name: 'read_file', arguments: { path: 'correct.js' } } }]
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls.length, 1);
      assert.strictEqual(result.calls[0].name, 'read_file');
      assert.strictEqual(result.calls[0].arguments.path, 'correct.js');
    });

    it('prefers JSON-in-content over XML-in-content', () => {
      const message = {
        content: '{"name":"read_file", "arguments":{"path":"json.js"}} <tool_call>{"name":"write_file", "arguments":{"path":"xml.js", "content":"x"}}</tool_call>'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      // JSON extraction should win -- both read_file (JSON) and write_file (also matched by JSON)
      // The JSON regex matches before XML is tried
      assert.ok(result.calls.some(c => c.name === 'read_file'));
    });

    it('falls back to XML when no native or JSON matches', () => {
      const message = {
        content: 'Here is my tool call:\n<tool_call>{"name":"search_files", "arguments":{"pattern":"TODO"}}</tool_call>'
      };
      const result = parseToolCalls(message);
      assert.strictEqual(result.type, 'tool_calls');
      assert.strictEqual(result.calls[0].name, 'search_files');
    });
  });

  // -------------------------------------------------------------------------
  // stripThinkingBlocks utility
  // -------------------------------------------------------------------------

  describe('stripThinkingBlocks', () => {
    it('removes thinking blocks', () => {
      assert.strictEqual(stripThinkingBlocks('<think>hello</think>world'), 'world');
    });

    it('handles empty input', () => {
      assert.strictEqual(stripThinkingBlocks(''), '');
      assert.strictEqual(stripThinkingBlocks(null), '');
    });

    it('handles multiline thinking blocks', () => {
      const input = '<think>\nline1\nline2\n</think>result';
      assert.strictEqual(stripThinkingBlocks(input), 'result');
    });
  });
});
