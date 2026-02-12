'use strict';

const { spawn } = require('child_process');
const { log } = require('../log');

/**
 * ClaudeExecutor -- invokes Claude Code CLI (`claude -p`) with
 * `--output-format stream-json` and captures streaming JSON events
 * including token usage from the final result event.
 *
 * Retries 2-3 times with exponential backoff (2s, 4s, 8s) per locked
 * decision.  No downgrade to lesser model -- complex tasks need Claude.
 */
class ClaudeExecutor {
  /**
   * Execute a task via Claude Code CLI.
   *
   * @param {object}   task       - Task object with description, context fields
   * @param {object}   config     - Sidecar config
   * @param {function} onProgress - Callback for streaming events
   * @returns {Promise<{status, output, model_used, tokens_in, tokens_out, error}>}
   */
  async execute(task, config, onProgress) {
    const routing = task.routing_decision || {};
    const model = routing.selected_model || 'claude-sonnet-4.5';
    const maxRetries = 3; // Retry 2-3 times (locked decision)
    const backoffDelays = [2000, 4000, 8000]; // Exponential backoff

    let lastError = null;

    for (let attempt = 1; attempt <= maxRetries + 1; attempt++) {
      try {
        if (attempt > 1) {
          const backoffMs = backoffDelays[attempt - 2] || 8000;
          onProgress({
            type: 'status',
            message: `Claude retry ${attempt - 1}/${maxRetries}, backing off ${backoffMs / 1000}s...`
          });
          log('info', 'claude_retry', {
            task_id: task.task_id,
            attempt: attempt - 1,
            max_retries: maxRetries,
            backoff_ms: backoffMs
          });
          await this._sleep(backoffMs);
        }

        const result = await this._invokeClaude(task, model, onProgress);

        return {
          status: 'success',
          output: result.fullOutput,
          model_used: model,
          tokens_in: result.tokensIn,
          tokens_out: result.tokensOut,
          error: null
        };
      } catch (err) {
        lastError = err;

        // Check for ENOENT -- Claude CLI not found (pitfall #2)
        if (err.code === 'ENOENT' || (err.message && err.message.includes('ENOENT'))) {
          onProgress({
            type: 'error',
            message: 'Claude Code CLI not found -- install via npm install -g @anthropic-ai/claude-code'
          });
          return {
            status: 'failed',
            output: '',
            model_used: model,
            tokens_in: 0,
            tokens_out: 0,
            error: 'Claude Code CLI not found -- install via npm install -g @anthropic-ai/claude-code'
          };
        }

        log('warning', 'claude_attempt_failed', {
          task_id: task.task_id,
          attempt,
          error: err.message
        });

        if (attempt > maxRetries) {
          onProgress({
            type: 'error',
            message: `Claude failed after ${maxRetries + 1} attempts: ${err.message}`
          });
          return {
            status: 'failed',
            output: '',
            model_used: model,
            tokens_in: 0,
            tokens_out: 0,
            error: err.message
          };
        }
      }
    }

    // Defensive fallback
    return {
      status: 'failed',
      output: '',
      model_used: model,
      tokens_in: 0,
      tokens_out: 0,
      error: lastError ? lastError.message : 'Unknown error'
    };
  }

  /**
   * Invoke `claude -p` with stream-json and parse streaming output.
   *
   * @returns {Promise<{fullOutput: string, tokensIn: number, tokensOut: number}>}
   */
  _invokeClaude(task, model, onProgress) {
    return new Promise((resolve, reject) => {
      const prompt = this._buildPrompt(task);

      const args = [
        '-p', prompt,
        '--output-format', 'stream-json',
        '--verbose'
      ];

      // Add model flag if specified
      if (model) {
        args.push('--model', model);
      }

      const proc = spawn('claude', args, {
        shell: true,
        windowsHide: true,
        env: { ...process.env } // Claude Code uses existing API key config
      });

      let fullOutput = '';
      let lastResult = null;
      let stdoutBuffer = '';

      proc.stdout.on('data', (data) => {
        stdoutBuffer += data.toString();
        // Parse streaming JSON events line-by-line
        const lines = stdoutBuffer.split('\n');
        stdoutBuffer = lines.pop(); // Keep incomplete line

        for (const line of lines) {
          if (!line.trim()) continue;
          try {
            const event = JSON.parse(line);

            // Text delta events -- stream tokens
            if (event.type === 'content_block_delta' &&
                event.delta && event.delta.type === 'text_delta') {
              const text = event.delta.text;
              fullOutput += text;
              onProgress({
                type: 'token',
                text,
                tokens_so_far: fullOutput.length, // Approximation
                model
              });
            }

            // Capture final result with usage stats
            if (event.type === 'result') {
              lastResult = event;
            }
          } catch (e) {
            // Non-JSON lines (status messages) -- skip
          }
        }
      });

      proc.stderr.on('data', (data) => {
        // Claude Code writes status info to stderr
        const text = data.toString().trim();
        if (text) {
          onProgress({ type: 'status', message: text });
        }
      });

      proc.on('close', (code) => {
        // Process any remaining buffer
        if (stdoutBuffer.trim()) {
          try {
            const event = JSON.parse(stdoutBuffer);
            if (event.type === 'result') {
              lastResult = event;
            }
            if (event.type === 'content_block_delta' &&
                event.delta && event.delta.type === 'text_delta') {
              fullOutput += event.delta.text;
            }
          } catch (e) {
            // Ignore
          }
        }

        if (code === 0) {
          // Handle missing usage data defensively (pitfall #5)
          const tokensIn = (lastResult && lastResult.usage && lastResult.usage.input_tokens) || 0;
          const tokensOut = (lastResult && lastResult.usage && lastResult.usage.output_tokens) || 0;

          // If no text was captured from deltas, try result.result
          if (!fullOutput && lastResult && lastResult.result) {
            fullOutput = lastResult.result;
          }

          resolve({ fullOutput, tokensIn, tokensOut });
        } else {
          reject(new Error(`Claude Code exited with code ${code}`));
        }
      });

      proc.on('error', (err) => {
        reject(err);
      });
    });
  }

  /**
   * Build prompt from task description and context fields.
   */
  _buildPrompt(task) {
    const parts = [];

    if (task.description) {
      parts.push(task.description);
    }

    // Add context for Claude to work with
    const contextParts = [];
    if (task.repo) contextParts.push(`Repository: ${task.repo}`);
    if (task.branch) contextParts.push(`Branch: ${task.branch}`);
    if (task.file_hints && task.file_hints.length > 0) {
      contextParts.push(`Relevant files: ${task.file_hints.join(', ')}`);
    }
    if (task.success_criteria && task.success_criteria.length > 0) {
      contextParts.push(`Success criteria:\n${task.success_criteria.map(c => `- ${c}`).join('\n')}`);
    }

    if (contextParts.length > 0) {
      parts.push('\nContext:\n' + contextParts.join('\n'));
    }

    return parts.join('\n') || 'Complete this task.';
  }

  _sleep(ms) {
    return new Promise(resolve => setTimeout(resolve, ms));
  }
}

module.exports = { ClaudeExecutor };
