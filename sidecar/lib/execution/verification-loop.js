'use strict';

const { dispatch } = require('./dispatcher');
const { runVerification } = require('../../verification');
const { log } = require('../log');

/**
 * Truncate a string to maxLen characters, appending '...(truncated)' if needed.
 *
 * @param {string} str - Input string
 * @param {number} maxLen - Maximum length before truncation
 * @returns {string}
 */
function truncate(str, maxLen) {
  if (!str) return '';
  if (str.length <= maxLen) return str;
  return str.slice(0, maxLen) + '...(truncated)';
}

/**
 * Count the number of checks with status !== 'pass' in a verification report.
 *
 * @param {object} report - Verification report with checks array
 * @returns {number}
 */
function countFailures(report) {
  if (!report || !report.checks) return 0;
  return report.checks.filter(c => c.status !== 'pass').length;
}

/**
 * Accumulate token counts and cost from an execution result into cumulative totals.
 * Handles null/undefined values as 0.
 *
 * @param {object} cumulative - { tokens_in, tokens_out, estimated_cost_usd }
 * @param {object} result - Execution result with token/cost fields
 */
function accumulateCost(cumulative, result) {
  cumulative.tokens_in += (result.tokens_in || 0);
  cumulative.tokens_out += (result.tokens_out || 0);
  cumulative.estimated_cost_usd += (result.estimated_cost_usd || 0);
}

/**
 * Build the final loop result, merging execution result with cumulative
 * cost/token fields and verification history.
 *
 * @param {object} execResult - Last execution result from dispatch()
 * @param {Array} reports - All verification reports from the loop
 * @param {object} cumulativeCost - Accumulated { tokens_in, tokens_out, estimated_cost_usd }
 * @param {string} status - 'verified' | 'partial_pass' | 'execution_failed'
 * @returns {object}
 */
function buildLoopResult(execResult, reports, cumulativeCost, status) {
  return {
    ...execResult,
    tokens_in: cumulativeCost.tokens_in,
    tokens_out: cumulativeCost.tokens_out,
    estimated_cost_usd: cumulativeCost.estimated_cost_usd,
    verification_report: reports.length > 0 ? reports[reports.length - 1] : null,
    verification_history: reports,
    verification_status: status,
    verification_attempts: reports.length
  };
}

/**
 * Build a corrective task by augmenting the original task description with
 * verification failure details. Separates checks into failed and passed,
 * constructing a prompt that guides the LLM to fix specific failures while
 * preserving passing checks.
 *
 * @param {object} originalTask - The original task object
 * @param {object} execResult - Last execution result (has output field)
 * @param {object} lastReport - Last verification report (has checks array)
 * @param {number} attempt - Current retry attempt number (1-based)
 * @returns {object} New task object with corrective prompt as description
 */
function buildCorrectiveTask(originalTask, execResult, lastReport, attempt) {
  const maxRetries = originalTask.max_verification_retries || 0;
  const checks = (lastReport && lastReport.checks) || [];

  const failed = checks.filter(c => c.status !== 'pass');
  const passed = checks.filter(c => c.status === 'pass');

  const failureContext = failed
    .map(c => `- ${c.type} (${c.target}): ${(c.status || 'unknown').toUpperCase()}\n  Output: ${truncate(c.output || '', 500)}`)
    .join('\n');

  const passedContext = passed
    .map(c => `- ${c.type} (${c.target}): PASS`)
    .join('\n');

  const originalDescription = originalTask._original_description || originalTask.description;

  const correctivePrompt = `VERIFICATION RETRY ${attempt}/${maxRetries}: Your previous work failed verification checks.

FAILED CHECKS:
${failureContext}

PASSED CHECKS (keep these passing):
${passedContext || '(none)'}

ORIGINAL TASK:
${originalDescription}

YOUR PREVIOUS OUTPUT:
${truncate(execResult.output || '', 1000)}

Fix the failing verification checks. Focus on the specific failures above.
Do not re-implement working parts -- only fix what is broken.`;

  return {
    ...originalTask,
    description: correctivePrompt,
    _original_description: originalDescription,
    _verification_attempt: attempt
  };
}

/**
 * Execute a task with bounded verification loop.
 *
 * For LLM executors (claude, ollama): dispatches the task, runs verification,
 * and on failure constructs a corrective prompt to retry. The loop is bounded
 * by max_verification_retries (default 0 = single attempt, no retries).
 *
 * For shell executor tasks (target_type 'sidecar'): single execution + single
 * verification, no retries. Deterministic shell commands have no LLM to correct.
 *
 * Cumulative token counts and cost are tracked across all retry iterations.
 *
 * @param {object} task - Task object with routing_decision, verification_steps, etc.
 * @param {object} config - Sidecar config (ollama_url, repo_dir, etc.)
 * @param {function} [onProgress] - Optional callback for streaming/status events
 * @returns {Promise<object>} Loop result with verification_status, verification_history, etc.
 */
async function executeWithVerification(task, config, onProgress) {
  const maxRetries = task.max_verification_retries || 0;
  const routing = task.routing_decision || {};
  const targetType = routing.target_type || 'ollama';
  const progressFn = onProgress || (() => {});

  log('info', 'verification_loop_start', {
    task_id: task.task_id,
    target_type: targetType,
    max_retries: maxRetries
  });

  const cumulativeCost = { tokens_in: 0, tokens_out: 0, estimated_cost_usd: 0 };
  const reports = [];

  // Shell executor tasks: single execution + single verification, no retries
  if (targetType === 'sidecar') {
    const execResult = await dispatch(task, config, progressFn);
    accumulateCost(cumulativeCost, execResult);

    if (execResult.status !== 'success') {
      log('info', 'verification_loop_complete', {
        task_id: task.task_id,
        status: 'execution_failed',
        attempts: 0
      });
      return buildLoopResult(execResult, reports, cumulativeCost, 'execution_failed');
    }

    const report = await runVerification(task, config, 1);
    reports.push(report);

    const status = (report.status === 'pass' || report.status === 'skip' || report.status === 'auto_pass')
      ? 'verified'
      : 'partial_pass';

    log('info', 'verification_loop_complete', {
      task_id: task.task_id,
      status,
      attempts: 1
    });

    return buildLoopResult(execResult, reports, cumulativeCost, status);
  }

  // LLM executors: bounded retry loop
  let currentTask = task;
  let lastExecResult = null;

  for (let attempt = 0; attempt <= maxRetries; attempt++) {
    // On retry, build corrective task from previous failure
    if (attempt > 0) {
      const lastReport = reports[reports.length - 1];
      const failCount = countFailures(lastReport);
      currentTask = buildCorrectiveTask(task, lastExecResult, lastReport, attempt);

      progressFn({
        type: 'status',
        message: `Verification retry ${attempt}/${maxRetries}: fixing ${failCount} failed checks...`
      });

      log('info', 'verification_retry_start', {
        task_id: task.task_id,
        attempt,
        max_retries: maxRetries,
        failed_checks: failCount
      });
    }

    // Dispatch task to LLM executor
    const execResult = await dispatch(currentTask, config, progressFn);
    accumulateCost(cumulativeCost, execResult);
    lastExecResult = execResult;

    // If execution itself failed, return immediately
    if (execResult.status !== 'success') {
      log('info', 'verification_loop_complete', {
        task_id: task.task_id,
        status: 'execution_failed',
        attempts: attempt + 1
      });
      return buildLoopResult(execResult, reports, cumulativeCost, 'execution_failed');
    }

    // Run verification with run_number = attempt + 1
    const report = await runVerification(task, config, attempt + 1);
    reports.push(report);

    // Check if verification passed
    if (report.status === 'pass' || report.status === 'skip' || report.status === 'auto_pass') {
      log('info', 'verification_loop_complete', {
        task_id: task.task_id,
        status: 'verified',
        attempts: attempt + 1
      });
      return buildLoopResult(execResult, reports, cumulativeCost, 'verified');
    }

    // Last attempt -- return partial_pass
    if (attempt === maxRetries) {
      log('info', 'verification_loop_complete', {
        task_id: task.task_id,
        status: 'partial_pass',
        attempts: attempt + 1
      });
      return buildLoopResult(execResult, reports, cumulativeCost, 'partial_pass');
    }

    // Otherwise: loop continues, next iteration will build corrective prompt
  }
}

module.exports = { executeWithVerification };
