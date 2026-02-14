'use strict';

/**
 * Agentic System Prompt Builder -- constructs the system prompt for
 * agentic execution with tool descriptions, workflow pattern, few-shot
 * examples, and task-specific context.
 *
 * Qwen3 8B benefits from concrete examples (locked decision).
 */

/**
 * Build the agentic system prompt for a task.
 *
 * @param {object} task - Task object with repo, branch, file_hints, success_criteria
 * @param {Array} toolDefinitions - Tool definitions from tool-registry
 * @returns {string} Complete system prompt string
 */
function buildAgenticSystemPrompt(task, toolDefinitions) {
  const sections = [];

  // Section 1: Role and context
  sections.push(buildRoleSection(task));

  // Section 2: Available tools
  sections.push(buildToolsSection(toolDefinitions));

  // Section 3: Workflow pattern
  sections.push(buildWorkflowSection());

  // Section 4: Few-shot example
  sections.push(buildExampleSection());

  // Section 5: Success criteria (if task has them)
  const criteriaSection = buildCriteriaSection(task);
  if (criteriaSection) {
    sections.push(criteriaSection);
  }

  // Section 6: Rules
  sections.push(buildRulesSection());

  return sections.join('\n\n');
}

/**
 * Section 1: Role and context
 */
function buildRoleSection(task) {
  const lines = [
    'You are a coding agent. You complete tasks by reading files, understanding code, making changes, and verifying your work.'
  ];

  if (task.repo) {
    lines.push(`Repository: ${task.repo}`);
  }
  if (task.branch) {
    lines.push(`Branch: ${task.branch}`);
  }
  if (task.file_hints && task.file_hints.length > 0) {
    lines.push(`Key files: ${task.file_hints.join(', ')}`);
  }

  return lines.join('\n');
}

/**
 * Section 2: Available tools
 */
function buildToolsSection(toolDefinitions) {
  const lines = ['## Available Tools', ''];

  if (!toolDefinitions || toolDefinitions.length === 0) {
    lines.push('No tools available.');
    return lines.join('\n');
  }

  for (const tool of toolDefinitions) {
    const fn = tool.function;
    const params = fn.parameters;
    const required = params.required || [];
    const props = params.properties || {};

    const paramDescs = Object.entries(props).map(([name, schema]) => {
      const req = required.includes(name) ? 'required' : 'optional';
      return `${name} (${req})`;
    });

    lines.push(`### ${fn.name}`);
    lines.push(`${fn.description} Args: ${paramDescs.join(', ')}`);
    lines.push('');
  }

  return lines.join('\n');
}

/**
 * Section 3: Workflow pattern
 */
function buildWorkflowSection() {
  return `## How to Complete Tasks

Follow this pattern:
1. UNDERSTAND: Read relevant files to understand the codebase
2. PLAN: Identify what needs to change (think step by step)
3. IMPLEMENT: Make changes using write_file
4. VERIFY: Run tests or commands to check your work

Always read before writing. Never guess at file contents.`;
}

/**
 * Section 4: Few-shot example
 */
function buildExampleSection() {
  return `## Example

Task: "Add a greeting function to utils.js"

Step 1 - Read the file:
Call read_file with path: "src/utils.js"

Step 2 - Understand current content, then write the update:
Call write_file with path: "src/utils.js", content: [updated content with new function]

Step 3 - Verify:
Call run_command with command: "node -e \\"require('./src/utils').greeting('world')\\""

Step 4 - Report completion:
"Done. Added greeting() function to src/utils.js. Verified it works by running it."`;
}

/**
 * Section 5: Success criteria (if task has them)
 */
function buildCriteriaSection(task) {
  if (!task.success_criteria || task.success_criteria.length === 0) {
    return null;
  }

  const lines = ['## Success Criteria'];
  for (const criterion of task.success_criteria) {
    lines.push(`- ${criterion}`);
  }
  return lines.join('\n');
}

/**
 * Section 6: Rules
 */
function buildRulesSection() {
  return `## Rules
- Call tools to do work. Do not just describe what you would do.
- When done, provide a brief summary of what you accomplished.
- If you encounter an error, try to fix it. If stuck, explain what went wrong.`;
}

module.exports = { buildAgenticSystemPrompt };
