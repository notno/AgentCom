'use strict';

const { calculateCost } = require('./cost-calculator');
const { log } = require('../log');

/**
 * Dispatch a task to the appropriate executor based on routing decision.
 *
 * Reads task.routing_decision.target_type to select the executor, with
 * fallback inference from task.complexity.effective_tier when routing
 * decision is absent.  After execution, computes cost fields via
 * cost-calculator and returns a uniform ExecutionResult.
 *
 * @param {object} task       - Task from task_assign (includes routing_decision, complexity)
 * @param {object} config     - Sidecar config (ollama_url, etc.)
 * @param {function} onProgress - Callback for streaming events
 * @returns {Promise<ExecutionResult>}
 */
async function dispatch(task, config, onProgress) {
  const routing = task.routing_decision || {};
  const targetType = routing.target_type || inferTargetType(task);

  log('info', 'execution_dispatch', {
    task_id: task.task_id,
    target_type: targetType,
    model: routing.selected_model || null,
    endpoint: routing.selected_endpoint || null
  });

  const startMs = Date.now();
  let rawResult;

  // Lazy-load executors to avoid requiring all at module load time
  switch (targetType) {
    case 'ollama': {
      const { OllamaExecutor } = require('./ollama-executor');
      rawResult = await new OllamaExecutor().execute(task, config, onProgress);
      break;
    }

    case 'claude': {
      const { ClaudeExecutor } = require('./claude-executor');
      rawResult = await new ClaudeExecutor().execute(task, config, onProgress);
      break;
    }

    case 'sidecar': {
      // Only use ShellExecutor if there's an explicit shell_command in metadata.
      // Otherwise, this is a natural-language task misclassified as trivial —
      // fall through to wake command (OpenClaw) for proper handling.
      if (task.metadata && task.metadata.shell_command) {
        const { ShellExecutor } = require('./shell-executor');
        rawResult = await new ShellExecutor().execute(task, config, onProgress);
      } else {
        // No shell command — reject with clear error so the task can be
        // retried or escalated. Don't silently pretend we handled it.
        onProgress({ type: 'status', message: 'No shell_command in metadata — task requires LLM routing, not sidecar execution' });
        rawResult = {
          status: 'failed',
          output: '',
          model_used: 'none',
          tokens_in: 0,
          tokens_out: 0,
          error: 'Task routed as trivial/sidecar but has no shell_command metadata. Needs LLM routing.'
        };
      }
      break;
    }

    default:
      throw new Error(`Unknown target type: ${targetType}`);
  }

  const executionMs = Date.now() - startMs;

  // Compute cost fields from cost-calculator (Plan 01)
  const costResult = calculateCost(
    rawResult.model_used,
    rawResult.tokens_in,
    rawResult.tokens_out
  );

  return {
    status: rawResult.status,
    output: rawResult.output,
    model_used: rawResult.model_used,
    tokens_in: rawResult.tokens_in,
    tokens_out: rawResult.tokens_out,
    estimated_cost_usd: costResult.cost_usd,
    equivalent_claude_cost_usd: costResult.equivalent_claude_cost_usd,
    execution_ms: executionMs,
    error: rawResult.error || null
  };
}

/**
 * Fallback inference when routing_decision is missing.
 * Uses complexity tier from Phase 17 enrichment.
 */
function inferTargetType(task) {
  const tier = task.complexity && task.complexity.effective_tier;
  switch (tier) {
    case 'trivial': return 'sidecar';
    case 'complex': return 'claude';
    case 'standard':
    default: return 'ollama';
  }
}

module.exports = { dispatch };
