'use strict';

const { describe, it } = require('node:test');
const assert = require('node:assert');
const { buildAgenticSystemPrompt } = require('../../lib/execution/agentic-prompt');
const { getToolDefinitions } = require('../../lib/tools/tool-registry');

describe('agentic-prompt', () => {
  const tools = getToolDefinitions();

  describe('buildAgenticSystemPrompt', () => {
    it('contains repo name when task.repo is set', () => {
      const task = { repo: 'my-cool-project' };
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(prompt.includes('my-cool-project'));
    });

    it('contains branch when task.branch is set', () => {
      const task = { branch: 'feature/test-branch' };
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(prompt.includes('feature/test-branch'));
    });

    it('contains file hints when present', () => {
      const task = { file_hints: ['src/main.js', 'lib/utils.js'] };
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(prompt.includes('src/main.js'));
      assert.ok(prompt.includes('lib/utils.js'));
    });

    it('lists all 5 tool names', () => {
      const task = {};
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(prompt.includes('read_file'));
      assert.ok(prompt.includes('write_file'));
      assert.ok(prompt.includes('list_directory'));
      assert.ok(prompt.includes('run_command'));
      assert.ok(prompt.includes('search_files'));
    });

    it('contains few-shot example section', () => {
      const task = {};
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(prompt.includes('## Example'));
      assert.ok(prompt.includes('Add a greeting function'));
      assert.ok(prompt.includes('Step 1'));
      assert.ok(prompt.includes('Step 2'));
    });

    it('contains success criteria when task has them', () => {
      const task = {
        success_criteria: ['Tests must pass', 'No lint errors']
      };
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(prompt.includes('## Success Criteria'));
      assert.ok(prompt.includes('Tests must pass'));
      assert.ok(prompt.includes('No lint errors'));
    });

    it('omits success criteria section when task has none', () => {
      const task = {};
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(!prompt.includes('## Success Criteria'));
    });

    it('omits success criteria section when empty array', () => {
      const task = { success_criteria: [] };
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(!prompt.includes('## Success Criteria'));
    });

    it('contains workflow pattern (UNDERSTAND, PLAN, IMPLEMENT, VERIFY)', () => {
      const task = {};
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(prompt.includes('UNDERSTAND'));
      assert.ok(prompt.includes('PLAN'));
      assert.ok(prompt.includes('IMPLEMENT'));
      assert.ok(prompt.includes('VERIFY'));
    });

    it('contains rules section', () => {
      const task = {};
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(prompt.includes('## Rules'));
      assert.ok(prompt.includes('Call tools to do work'));
    });

    it('contains coding agent role description', () => {
      const task = {};
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(prompt.includes('coding agent'));
    });

    it('handles empty tool definitions', () => {
      const task = {};
      const prompt = buildAgenticSystemPrompt(task, []);
      assert.ok(prompt.includes('No tools available'));
    });

    it('includes tool parameter descriptions with required/optional', () => {
      const task = {};
      const prompt = buildAgenticSystemPrompt(task, tools);
      assert.ok(prompt.includes('(required)'));
      assert.ok(prompt.includes('(optional)'));
    });
  });
});
