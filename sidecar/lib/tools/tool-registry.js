'use strict';

/**
 * Tool Registry -- defines 5 tools in Ollama function-calling JSON format.
 *
 * Qwen3 8B supports up to 5 tools natively via JSON; above 5 falls back
 * to XML in content field. These 5 tools cover the core agentic operations:
 * file I/O, directory listing, shell commands, and code search.
 *
 * Each tool follows the Ollama /api/chat tools array format:
 * { type: 'function', function: { name, description, parameters: { type: 'object', properties, required } } }
 */

const TOOLS = [
  {
    type: 'function',
    function: {
      name: 'read_file',
      description: 'Read the contents of a file. Returns content with line numbers. Use start_line/end_line to read a specific range.',
      parameters: {
        type: 'object',
        properties: {
          path: {
            type: 'string',
            description: 'File path relative to workspace root'
          },
          start_line: {
            type: 'integer',
            description: 'Starting line number (1-based, optional)'
          },
          end_line: {
            type: 'integer',
            description: 'Ending line number (inclusive, optional)'
          }
        },
        required: ['path']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'write_file',
      description: 'Write content to a file. Creates parent directories if needed. Overwrites existing content.',
      parameters: {
        type: 'object',
        properties: {
          path: {
            type: 'string',
            description: 'File path relative to workspace root'
          },
          content: {
            type: 'string',
            description: 'Content to write to the file'
          },
          create_dirs: {
            type: 'boolean',
            description: 'Create parent directories if they do not exist (default: true)'
          }
        },
        required: ['path', 'content']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'list_directory',
      description: 'List files and directories at the given path. Use recursive=true for deep listing. Use pattern for glob filtering.',
      parameters: {
        type: 'object',
        properties: {
          path: {
            type: 'string',
            description: 'Directory path relative to workspace root'
          },
          recursive: {
            type: 'boolean',
            description: 'List subdirectories recursively (default: false)'
          },
          pattern: {
            type: 'string',
            description: 'Glob pattern to filter entries (e.g., "*.js")'
          }
        },
        required: ['path']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'run_command',
      description: 'Execute a shell command in the workspace directory. Returns stdout, stderr, and exit code. Timeout default 30 seconds.',
      parameters: {
        type: 'object',
        properties: {
          command: {
            type: 'string',
            description: 'Shell command to execute'
          },
          timeout_ms: {
            type: 'integer',
            description: 'Command timeout in milliseconds (default: 30000)'
          }
        },
        required: ['command']
      }
    }
  },
  {
    type: 'function',
    function: {
      name: 'search_files',
      description: 'Search for a regex pattern across files. Returns matching lines with file paths and line numbers. Max 50 results.',
      parameters: {
        type: 'object',
        properties: {
          pattern: {
            type: 'string',
            description: 'Regular expression pattern to search for'
          },
          path: {
            type: 'string',
            description: 'Directory to search in, relative to workspace (default: ".")'
          },
          file_pattern: {
            type: 'string',
            description: 'Glob pattern to filter files (e.g., "*.js")'
          },
          max_results: {
            type: 'integer',
            description: 'Maximum number of matching lines to return (default: 50)'
          }
        },
        required: ['pattern']
      }
    }
  }
];

/**
 * Get all tool definitions for passing to Ollama /api/chat tools parameter.
 * @returns {Array} Array of tool definition objects
 */
function getToolDefinitions() {
  return TOOLS;
}

/**
 * Find a tool definition by name.
 * @param {string} name - Tool function name (e.g., 'read_file')
 * @returns {object|null} Tool definition or null if not found
 */
function getToolByName(name) {
  return TOOLS.find(t => t.function.name === name) || null;
}

module.exports = { getToolDefinitions, getToolByName, TOOLS };
