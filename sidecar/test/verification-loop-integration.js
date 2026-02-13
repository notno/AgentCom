'use strict';

/**
 * Integration test for the verification retry loop.
 *
 * Exercises the complete failure -> corrective-prompt -> retry flow through
 * executeWithVerification using module stubbing. Proves the real loop module
 * orchestrates the retry flow correctly without requiring a live hub or LLM.
 *
 * Phase 22 Plan 02 Task 3
 */

const Module = require('module');
const path = require('path');

// ---------------------------------------------------------------------------
// Stub Setup: Replace dispatcher, verification, and log modules in require cache
// ---------------------------------------------------------------------------

const loopPath = path.resolve(__dirname, '../lib/execution/verification-loop.js');

// Clear require cache to ensure fresh load
delete require.cache[loopPath];

// Stub dispatcher.dispatch -- track calls, return success
const dispatcherPath = path.resolve(__dirname, '../lib/execution/dispatcher.js');
const dispatchCalls = [];
require.cache[dispatcherPath] = {
  id: dispatcherPath, filename: dispatcherPath, loaded: true,
  exports: {
    dispatch: async (task, config, onProgress) => {
      dispatchCalls.push({ task, config });
      return {
        status: 'success',
        output: 'mock output',
        tokens_in: 100,
        tokens_out: 50,
        estimated_cost_usd: 0.01,
        equivalent_claude_cost_usd: 0.02,
        execution_ms: 500,
        model_used: 'test-model'
      };
    }
  }
};

// Stub verification -- fail on run 1, pass on run 2
const verificationPath = path.resolve(__dirname, '../verification.js');
let verifyCallCount = 0;
require.cache[verificationPath] = {
  id: verificationPath, filename: verificationPath, loaded: true,
  exports: {
    runVerification: async (task, config, runNumber) => {
      verifyCallCount++;
      if (verifyCallCount === 1) {
        return {
          status: 'fail', run_number: runNumber,
          summary: { total: 2, passed: 1, failed: 1 },
          checks: [
            { type: 'command', target: 'npm test', status: 'pass', output: 'ok' },
            { type: 'command', target: 'npm run lint', status: 'fail', output: 'Error: unused var' }
          ]
        };
      }
      return {
        status: 'pass', run_number: runNumber,
        summary: { total: 2, passed: 2, failed: 0 },
        checks: [
          { type: 'command', target: 'npm test', status: 'pass', output: 'ok' },
          { type: 'command', target: 'npm run lint', status: 'pass', output: 'ok' }
        ]
      };
    }
  }
};

// Stub log module to suppress output
const logPath = path.resolve(__dirname, '../lib/log.js');
const noop = () => {};
require.cache[logPath] = {
  id: logPath, filename: logPath, loaded: true,
  exports: { initLogger: noop, log: noop, LEVELS: {} }
};

// ---------------------------------------------------------------------------
// Load and Execute
// ---------------------------------------------------------------------------

const { executeWithVerification } = require(loopPath);

(async () => {
  const task = {
    task_id: 'test-retry-001',
    description: 'Fix the lint errors',
    max_verification_retries: 2,
    routing_decision: { target_type: 'claude' },
    verification_checks: [
      { type: 'command', target: 'npm test' },
      { type: 'command', target: 'npm run lint' }
    ]
  };
  const config = { working_dir: '/tmp/test' };
  const progressEvents = [];

  const result = await executeWithVerification(task, config, (event) => progressEvents.push(event));

  // ---------------------------------------------------------------------------
  // Assertions
  // ---------------------------------------------------------------------------

  let failures = 0;
  function assert(condition, msg) {
    if (!condition) { console.error('FAIL:', msg); failures++; }
    else { console.log('PASS:', msg); }
  }

  // A1: dispatch was called twice (initial + retry)
  assert(dispatchCalls.length === 2, 'dispatch called twice (initial + corrective retry)');

  // A2: second dispatch received corrective prompt, not original description
  assert(dispatchCalls[1].task.description.includes('VERIFICATION RETRY'),
    'retry task contains corrective prompt with VERIFICATION RETRY header');

  // A3: corrective prompt includes the failed check details
  assert(dispatchCalls[1].task.description.includes('npm run lint'),
    'corrective prompt references the specific failed check (npm run lint)');

  // A4: corrective prompt preserves original task description
  assert(dispatchCalls[1].task.description.includes('Fix the lint errors'),
    'corrective prompt includes original task description');

  // A5: result has verified status (second attempt passed)
  assert(result.verification_status === 'verified',
    'final status is verified after successful retry');

  // A6: verification history contains 2 reports
  assert(result.verification_history && result.verification_history.length === 2,
    'verification_history contains 2 reports (fail then pass)');

  // A7: cumulative cost tracked across both iterations
  assert(result.estimated_cost_usd > 0.01,
    'cumulative cost reflects both iterations (> single-iteration cost)');

  if (failures > 0) {
    console.error(`\n${failures} assertion(s) FAILED`);
    process.exit(1);
  } else {
    console.log('\nAll assertions passed -- verification retry loop works end-to-end');
  }
})().catch(err => {
  console.error('Test error:', err);
  process.exit(1);
});
