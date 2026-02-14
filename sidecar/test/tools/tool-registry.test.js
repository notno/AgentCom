'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { getToolDefinitions, getToolByName, TOOLS } = require('../../lib/tools/tool-registry');

describe('ToolRegistry', () => {
  describe('getToolDefinitions', () => {
    it('returns exactly 5 tools', () => {
      const tools = getToolDefinitions();
      assert.strictEqual(tools.length, 5);
    });

    it('returns the same array as TOOLS export', () => {
      assert.strictEqual(getToolDefinitions(), TOOLS);
    });
  });

  describe('tool definition structure', () => {
    const tools = getToolDefinitions();

    for (const tool of tools) {
      describe(`${tool.function.name}`, () => {
        it('has type "function"', () => {
          assert.strictEqual(tool.type, 'function');
        });

        it('has function.name as a non-empty string', () => {
          assert.strictEqual(typeof tool.function.name, 'string');
          assert.ok(tool.function.name.length > 0);
        });

        it('has function.description as a non-empty string', () => {
          assert.strictEqual(typeof tool.function.description, 'string');
          assert.ok(tool.function.description.length > 0);
        });

        it('has function.parameters with type "object"', () => {
          assert.strictEqual(tool.function.parameters.type, 'object');
        });

        it('has function.parameters.properties as an object', () => {
          assert.strictEqual(typeof tool.function.parameters.properties, 'object');
          assert.ok(tool.function.parameters.properties !== null);
        });

        it('has function.parameters.required as an array', () => {
          assert.ok(Array.isArray(tool.function.parameters.required));
          assert.ok(tool.function.parameters.required.length > 0);
        });

        it('required fields are defined in properties', () => {
          const props = Object.keys(tool.function.parameters.properties);
          for (const req of tool.function.parameters.required) {
            assert.ok(props.includes(req), `Required field "${req}" missing from properties`);
          }
        });
      });
    }
  });

  describe('expected tool names', () => {
    const expectedNames = ['read_file', 'write_file', 'list_directory', 'run_command', 'search_files'];

    it('contains all 5 expected tool names', () => {
      const tools = getToolDefinitions();
      const names = tools.map(t => t.function.name);
      for (const expected of expectedNames) {
        assert.ok(names.includes(expected), `Missing tool: ${expected}`);
      }
    });

    it('contains no unexpected tool names', () => {
      const tools = getToolDefinitions();
      const names = tools.map(t => t.function.name);
      for (const name of names) {
        assert.ok(expectedNames.includes(name), `Unexpected tool: ${name}`);
      }
    });
  });

  describe('getToolByName', () => {
    it('returns correct tool for each known name', () => {
      const names = ['read_file', 'write_file', 'list_directory', 'run_command', 'search_files'];
      for (const name of names) {
        const tool = getToolByName(name);
        assert.ok(tool !== null, `getToolByName("${name}") returned null`);
        assert.strictEqual(tool.function.name, name);
      }
    });

    it('returns null for unknown tool name', () => {
      assert.strictEqual(getToolByName('nonexistent_tool'), null);
    });

    it('returns null for empty string', () => {
      assert.strictEqual(getToolByName(''), null);
    });
  });
});
