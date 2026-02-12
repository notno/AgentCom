'use strict';

const http = require('http');
const { log } = require('../log');

/**
 * OllamaExecutor -- calls Ollama /api/chat with streaming NDJSON,
 * collects token counts from the final `done: true` message, and
 * retries 1-2 times locally on failure (per locked decision).
 */
class OllamaExecutor {
  /**
   * Execute a task against an Ollama endpoint.
   *
   * @param {object}   task       - Task object with routing_decision, description, etc.
   * @param {object}   config     - Sidecar config (ollama_url fallback)
   * @param {function} onProgress - Callback for streaming events
   * @returns {Promise<{status, output, model_used, tokens_in, tokens_out, error}>}
   */
  async execute(task, config, onProgress) {
    const routing = task.routing_decision || {};
    const model = routing.selected_model || 'llama3.2:latest';
    const endpoint = this._parseEndpoint(routing.selected_endpoint, config);
    const maxRetries = 2; // Retry 1-2 times (locked decision)

    let lastError = null;

    for (let attempt = 1; attempt <= maxRetries + 1; attempt++) {
      try {
        if (attempt > 1) {
          onProgress({
            type: 'status',
            message: `Ollama retry ${attempt - 1}/${maxRetries}...`
          });
          log('info', 'ollama_retry', {
            task_id: task.task_id,
            attempt: attempt - 1,
            max_retries: maxRetries
          });
        }

        const result = await this._streamChat(endpoint, model, task, onProgress);

        return {
          status: 'success',
          output: result.fullResponse,
          model_used: model,
          tokens_in: result.tokensIn,
          tokens_out: result.tokensOut,
          error: null
        };
      } catch (err) {
        lastError = err;
        log('warning', 'ollama_attempt_failed', {
          task_id: task.task_id,
          attempt,
          error: err.message
        });

        if (attempt > maxRetries) {
          // All retries exhausted -- return failed result
          // Hub will reassign to a different endpoint
          onProgress({
            type: 'error',
            message: `Ollama failed after ${maxRetries + 1} attempts: ${err.message}`
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

    // Should not reach here, but defensive
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
   * Parse endpoint from routing_decision.selected_endpoint (format: "host:port")
   * or fall back to config.ollama_url.
   */
  _parseEndpoint(selectedEndpoint, config) {
    if (selectedEndpoint) {
      const parts = selectedEndpoint.split(':');
      if (parts.length >= 2) {
        const port = parseInt(parts[parts.length - 1], 10);
        const host = parts.slice(0, -1).join(':');
        if (!isNaN(port)) {
          return { hostname: host, port };
        }
      }
      // If format is unexpected, treat as hostname with default port
      return { hostname: selectedEndpoint, port: 11434 };
    }

    // Fall back to config.ollama_url
    if (config.ollama_url) {
      try {
        const url = new URL(config.ollama_url);
        return { hostname: url.hostname, port: parseInt(url.port, 10) || 11434 };
      } catch (e) {
        // Malformed URL, use defaults
      }
    }

    return { hostname: 'localhost', port: 11434 };
  }

  /**
   * Stream a chat completion from Ollama /api/chat.
   *
   * Parses streaming NDJSON response line-by-line using buffer + newline
   * split pattern (per research pitfall #3: buffer incomplete lines across chunks).
   *
   * @returns {Promise<{fullResponse: string, tokensIn: number, tokensOut: number}>}
   */
  _streamChat(endpoint, model, task, onProgress) {
    return new Promise((resolve, reject) => {
      const messages = this._buildMessages(task);
      const body = JSON.stringify({
        model,
        messages,
        stream: true
      });

      const options = {
        hostname: endpoint.hostname,
        port: endpoint.port,
        path: '/api/chat',
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Content-Length': Buffer.byteLength(body)
        },
        timeout: 300000 // 5-minute timeout for long generations
      };

      const req = http.request(options, (res) => {
        if (res.statusCode !== 200) {
          let errBody = '';
          res.on('data', (chunk) => { errBody += chunk; });
          res.on('end', () => {
            reject(new Error(`Ollama HTTP ${res.statusCode}: ${errBody.slice(0, 500)}`));
          });
          return;
        }

        let buffer = '';
        let fullResponse = '';
        let tokensOut = 0;
        let tokensIn = 0;

        res.on('data', (chunk) => {
          buffer += chunk.toString();
          // Split on newlines -- NDJSON protocol
          const lines = buffer.split('\n');
          buffer = lines.pop(); // Keep incomplete line in buffer

          for (const line of lines) {
            if (!line.trim()) continue;
            try {
              const parsed = JSON.parse(line);
              if (parsed.done) {
                // Final message -- extract token counts
                // Default prompt_eval_count to 0 when absent (pitfall #1: Ollama caches prompt evals)
                tokensIn = parsed.prompt_eval_count || 0;
                tokensOut = parsed.eval_count || 0;

                // Also collect any final message content
                if (parsed.message && parsed.message.content) {
                  fullResponse += parsed.message.content;
                }
              } else if (parsed.message && parsed.message.content) {
                fullResponse += parsed.message.content;
                onProgress({
                  type: 'token',
                  text: parsed.message.content,
                  tokens_so_far: fullResponse.length, // Approximation until done
                  model
                });
              }
            } catch (e) {
              // Skip unparseable lines (pitfall #3)
              log('debug', 'ollama_ndjson_parse_skip', { line: line.slice(0, 200) });
            }
          }
        });

        res.on('end', () => {
          // Process any remaining buffer content
          if (buffer.trim()) {
            try {
              const parsed = JSON.parse(buffer);
              if (parsed.done) {
                tokensIn = parsed.prompt_eval_count || 0;
                tokensOut = parsed.eval_count || 0;
              }
              if (parsed.message && parsed.message.content) {
                fullResponse += parsed.message.content;
              }
            } catch (e) {
              // Ignore
            }
          }

          resolve({ fullResponse, tokensIn, tokensOut });
        });

        res.on('error', reject);
      });

      req.on('timeout', () => {
        req.destroy();
        reject(new Error('Ollama request timeout (5 min)'));
      });

      req.on('error', reject);
      req.write(body);
      req.end();
    });
  }

  /**
   * Build messages array: system prompt from task context, user message from description.
   */
  _buildMessages(task) {
    const messages = [];

    // System prompt with task context
    const systemParts = [];
    if (task.repo) systemParts.push(`Repository: ${task.repo}`);
    if (task.branch) systemParts.push(`Branch: ${task.branch}`);
    if (task.file_hints && task.file_hints.length > 0) {
      systemParts.push(`Relevant files: ${task.file_hints.join(', ')}`);
    }
    if (task.success_criteria && task.success_criteria.length > 0) {
      systemParts.push(`Success criteria:\n${task.success_criteria.map(c => `- ${c}`).join('\n')}`);
    }

    if (systemParts.length > 0) {
      messages.push({
        role: 'system',
        content: `You are a helpful coding assistant.\n\n${systemParts.join('\n')}`
      });
    }

    // User message from task description
    messages.push({
      role: 'user',
      content: task.description || 'Complete this task.'
    });

    return messages;
  }
}

module.exports = { OllamaExecutor };
