'use strict';

const http = require('http');
const { log } = require('../log');
const { parseToolCalls } = require('./tool-call-parser');
const { getToolDefinitions } = require('../tools/tool-registry');
const { executeTool } = require('../tools/tool-executor');

/**
 * OllamaExecutor -- calls Ollama /api/chat with streaming NDJSON,
 * collects token counts from the final `done: true` message, and
 * retries 1-2 times locally on failure (per locked decision).
 *
 * Phase 41: Also supports multi-turn agentic ReAct loop with tool calling.
 */
class OllamaExecutor {
  /**
   * Execute a task against an Ollama endpoint.
   *
   * Routes to agentic loop when task.routing_decision.agentic === true
   * or task._agentic === true. Otherwise uses single-shot streaming.
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

    // Phase 41: Route to agentic loop if flagged
    if (routing.agentic === true || task._agentic === true) {
      return this._agenticLoop(endpoint, model, task, config, onProgress);
    }

    // Single-shot streaming path (original behavior)
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
   * Non-streaming Ollama call (stream: false).
   * Returns the full parsed JSON response object.
   *
   * @param {object} endpoint - { hostname, port }
   * @param {string} model - Model name
   * @param {Array} messages - Chat messages array
   * @param {Array} tools - Tool definitions array
   * @returns {Promise<object>} Full Ollama response (has message, done, prompt_eval_count, eval_count)
   */
  _chatOnce(endpoint, model, messages, tools) {
    return new Promise((resolve, reject) => {
      const body = JSON.stringify({
        model,
        messages,
        tools: tools && tools.length > 0 ? tools : undefined,
        stream: false
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
        timeout: 120000 // 120-second timeout per call
      };

      const req = http.request(options, (res) => {
        let data = '';
        res.on('data', (chunk) => { data += chunk.toString(); });
        res.on('end', () => {
          if (res.statusCode !== 200) {
            reject(new Error(`Ollama HTTP ${res.statusCode}: ${data.slice(0, 500)}`));
            return;
          }
          try {
            const parsed = JSON.parse(data);
            resolve(parsed);
          } catch (e) {
            reject(new Error(`Ollama response parse error: ${e.message}`));
          }
        });
        res.on('error', reject);
      });

      req.on('timeout', () => {
        req.destroy();
        reject(new Error('Ollama _chatOnce timeout (120s)'));
      });

      req.on('error', reject);
      req.write(body);
      req.end();
    });
  }

  /**
   * Multi-turn ReAct loop for agentic execution.
   *
   * 1. Builds initial messages with system prompt + task description
   * 2. Gets tool definitions from tool registry
   * 3. Loops: call Ollama -> parse tool_calls -> execute tools -> feed results back
   * 4. Exits when model returns final answer or max iterations reached
   *
   * @param {object} endpoint - { hostname, port }
   * @param {string} model - Model name
   * @param {object} task - Task object
   * @param {object} config - Sidecar config
   * @param {function} onProgress - Progress callback
   * @returns {Promise<object>} Execution result
   */
  async _agenticLoop(endpoint, model, task, config, onProgress) {
    const maxIterations = task._agentic_max_iterations || 10;
    const workspace = config.repo_dir || config.workspace || process.cwd();
    const tools = getToolDefinitions();
    let nudgeCount = 0;
    const maxNudges = 2;

    // Build initial messages
    const systemContent = this._buildMessages(task)[0];
    const messages = [];

    // System message
    if (systemContent && systemContent.role === 'system') {
      messages.push(systemContent);
    } else {
      messages.push({
        role: 'system',
        content: 'You are a helpful coding assistant. Use the available tools to complete the task.'
      });
    }

    // User message
    messages.push({
      role: 'user',
      content: task.description || 'Complete this task.'
    });

    // Token accumulators
    let totalTokensIn = 0;
    let totalTokensOut = 0;
    let lastContent = '';
    let terminationReason = 'max_iterations';

    log('info', 'agentic_loop_start', {
      task_id: task.task_id,
      model,
      max_iterations: maxIterations,
      workspace
    });

    onProgress({
      type: 'status',
      message: `Agentic loop started (max ${maxIterations} iterations)`
    });

    for (let i = 0; i < maxIterations; i++) {
      let response;
      try {
        response = await this._chatOnce(endpoint, model, messages, tools);
      } catch (err) {
        log('error', 'agentic_chatonce_error', {
          task_id: task.task_id,
          iteration: i,
          error: err.message
        });
        return {
          status: 'failed',
          output: lastContent || '',
          model_used: model,
          tokens_in: totalTokensIn,
          tokens_out: totalTokensOut,
          error: err.message,
          termination_reason: 'error',
          iterations_used: i
        };
      }

      // Track token counts
      totalTokensIn += (response.prompt_eval_count || 0);
      totalTokensOut += (response.eval_count || 0);

      // Parse response
      const parsed = parseToolCalls(response.message);

      if (parsed.type === 'final_answer') {
        lastContent = parsed.content;
        terminationReason = 'final_answer';
        log('info', 'agentic_final_answer', {
          task_id: task.task_id,
          iteration: i,
          content_length: parsed.content.length
        });
        break;
      }

      if (parsed.type === 'tool_calls') {
        nudgeCount = 0; // Reset nudge count on successful tool calls

        // Append assistant message to conversation
        messages.push({
          role: 'assistant',
          content: response.message.content || '',
          tool_calls: response.message.tool_calls
        });

        // Execute each tool call
        for (const call of parsed.calls) {
          onProgress({
            type: 'tool_call',
            tool_name: call.name,
            args_summary: JSON.stringify(call.arguments).slice(0, 200),
            iteration: i
          });

          log('info', 'agentic_tool_call', {
            task_id: task.task_id,
            iteration: i,
            tool: call.name,
            args: JSON.stringify(call.arguments).slice(0, 200)
          });

          const toolResult = await executeTool(call.name, call.arguments, workspace);

          // Append tool result to conversation
          messages.push({
            role: 'tool',
            content: JSON.stringify(toolResult)
          });

          log('info', 'agentic_tool_result', {
            task_id: task.task_id,
            iteration: i,
            tool: call.name,
            success: toolResult.success
          });
        }

        continue;
      }

      if (parsed.type === 'empty') {
        nudgeCount++;
        if (nudgeCount >= maxNudges) {
          terminationReason = 'nudge_exhausted';
          log('warning', 'agentic_nudge_exhausted', {
            task_id: task.task_id,
            iteration: i
          });
          break;
        }

        // Nudge the model
        messages.push({
          role: 'user',
          content: 'Please use the available tools to complete the task. Do not just describe what to do -- actually call the tools.'
        });

        log('info', 'agentic_nudge', {
          task_id: task.task_id,
          iteration: i,
          nudge_count: nudgeCount
        });
      }
    }

    log('info', 'agentic_loop_end', {
      task_id: task.task_id,
      termination_reason: terminationReason,
      tokens_in: totalTokensIn,
      tokens_out: totalTokensOut
    });

    onProgress({
      type: 'status',
      message: `Agentic loop complete: ${terminationReason}`
    });

    return {
      status: 'success',
      output: lastContent || '',
      model_used: model,
      tokens_in: totalTokensIn,
      tokens_out: totalTokensOut,
      error: null,
      termination_reason: terminationReason,
      iterations_used: maxIterations
    };
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
