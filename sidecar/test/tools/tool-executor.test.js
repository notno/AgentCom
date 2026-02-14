'use strict';

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { executeTool } = require('../../lib/tools/tool-executor');

describe('ToolExecutor', () => {
  let workspaceRoot;

  before(() => {
    workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'tool-executor-test-'));
  });

  after(() => {
    fs.rmSync(workspaceRoot, { recursive: true, force: true });
  });

  // -------------------------------------------------------------------------
  // Dispatch
  // -------------------------------------------------------------------------

  describe('executeTool dispatch', () => {
    it('returns error for unknown tool name', async () => {
      const result = await executeTool('nonexistent_tool', {}, workspaceRoot);
      assert.strictEqual(result.success, false);
      assert.strictEqual(result.tool, 'nonexistent_tool');
      assert.strictEqual(result.error.code, 'UNKNOWN_TOOL');
      assert.strictEqual(result.output, null);
    });

    it('returns structured JSON envelope for known tools', async () => {
      // Create a file so read_file succeeds
      fs.writeFileSync(path.join(workspaceRoot, 'envelope-test.txt'), 'hello');
      const result = await executeTool('read_file', { path: 'envelope-test.txt' }, workspaceRoot);
      assert.strictEqual(typeof result.success, 'boolean');
      assert.strictEqual(typeof result.tool, 'string');
      assert.ok('output' in result);
      assert.ok('error' in result);
    });
  });

  // -------------------------------------------------------------------------
  // read_file
  // -------------------------------------------------------------------------

  describe('read_file', () => {
    it('reads a text file and returns content with line count', async () => {
      const content = 'line 1\nline 2\nline 3';
      fs.writeFileSync(path.join(workspaceRoot, 'read-test.txt'), content);

      const result = await executeTool('read_file', { path: 'read-test.txt' }, workspaceRoot);
      assert.strictEqual(result.success, true);
      assert.strictEqual(result.tool, 'read_file');
      assert.strictEqual(result.output.content, content);
      assert.strictEqual(result.output.lines, 3);
      assert.strictEqual(result.output.path, 'read-test.txt');
      assert.strictEqual(result.error, null);
    });

    it('respects start_line and end_line (1-based inclusive)', async () => {
      const content = 'line 1\nline 2\nline 3\nline 4\nline 5';
      fs.writeFileSync(path.join(workspaceRoot, 'range-test.txt'), content);

      const result = await executeTool('read_file', {
        path: 'range-test.txt',
        start_line: 2,
        end_line: 4
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      assert.strictEqual(result.output.content, 'line 2\nline 3\nline 4');
      assert.strictEqual(result.output.lines, 3);
      assert.strictEqual(result.output.truncated, true);
    });

    it('rejects path traversal', async () => {
      const result = await executeTool('read_file', {
        path: '../../../etc/passwd'
      }, workspaceRoot);

      assert.strictEqual(result.success, false);
      assert.strictEqual(result.error.code, 'PATH_OUTSIDE_WORKSPACE');
    });

    it('returns error for nonexistent file', async () => {
      const result = await executeTool('read_file', {
        path: 'no-such-file.txt'
      }, workspaceRoot);

      assert.strictEqual(result.success, false);
      assert.strictEqual(result.error.code, 'FILE_NOT_FOUND');
    });

    it('returns FILE_TOO_LARGE for files > 1MB', async () => {
      const largePath = path.join(workspaceRoot, 'large-file.txt');
      // Create a file just over 1MB
      const buf = Buffer.alloc(1024 * 1024 + 100, 'a');
      fs.writeFileSync(largePath, buf);

      const result = await executeTool('read_file', {
        path: 'large-file.txt'
      }, workspaceRoot);

      assert.strictEqual(result.success, false);
      assert.strictEqual(result.error.code, 'FILE_TOO_LARGE');
    });
  });

  // -------------------------------------------------------------------------
  // write_file
  // -------------------------------------------------------------------------

  describe('write_file', () => {
    it('writes a new file and returns bytes_written', async () => {
      const result = await executeTool('write_file', {
        path: 'new-file.txt',
        content: 'hello world'
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      assert.strictEqual(result.output.bytes_written, Buffer.byteLength('hello world', 'utf-8'));
      assert.strictEqual(result.output.created, true);
      assert.strictEqual(result.output.path, 'new-file.txt');

      // Verify file actually exists
      const written = fs.readFileSync(path.join(workspaceRoot, 'new-file.txt'), 'utf-8');
      assert.strictEqual(written, 'hello world');
    });

    it('creates parent directories automatically', async () => {
      const result = await executeTool('write_file', {
        path: 'deep/nested/dir/auto-created.txt',
        content: 'deep content'
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      assert.strictEqual(result.output.created, true);
      assert.ok(fs.existsSync(path.join(workspaceRoot, 'deep', 'nested', 'dir', 'auto-created.txt')));
    });

    it('overwrites existing file and returns created: false', async () => {
      const filePath = path.join(workspaceRoot, 'overwrite-test.txt');
      fs.writeFileSync(filePath, 'original');

      const result = await executeTool('write_file', {
        path: 'overwrite-test.txt',
        content: 'replaced'
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      assert.strictEqual(result.output.created, false);

      const content = fs.readFileSync(filePath, 'utf-8');
      assert.strictEqual(content, 'replaced');
    });

    it('rejects path traversal', async () => {
      const result = await executeTool('write_file', {
        path: '../../evil.txt',
        content: 'malicious'
      }, workspaceRoot);

      assert.strictEqual(result.success, false);
      assert.strictEqual(result.error.code, 'PATH_OUTSIDE_WORKSPACE');
    });
  });

  // -------------------------------------------------------------------------
  // list_directory
  // -------------------------------------------------------------------------

  describe('list_directory', () => {
    before(() => {
      // Create test directory structure
      fs.mkdirSync(path.join(workspaceRoot, 'listdir', 'sub'), { recursive: true });
      fs.writeFileSync(path.join(workspaceRoot, 'listdir', 'a.txt'), 'a');
      fs.writeFileSync(path.join(workspaceRoot, 'listdir', 'b.js'), 'b');
      fs.writeFileSync(path.join(workspaceRoot, 'listdir', 'sub', 'c.txt'), 'c');
    });

    it('lists files and directories with correct types', async () => {
      const result = await executeTool('list_directory', {
        path: 'listdir'
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      const names = result.output.entries.map(e => e.name);
      assert.ok(names.includes('a.txt'));
      assert.ok(names.includes('b.js'));
      assert.ok(names.includes('sub'));

      const subEntry = result.output.entries.find(e => e.name === 'sub');
      assert.strictEqual(subEntry.type, 'directory');

      const fileEntry = result.output.entries.find(e => e.name === 'a.txt');
      assert.strictEqual(fileEntry.type, 'file');
      assert.strictEqual(typeof fileEntry.size, 'number');
    });

    it('recursive listing includes subdirectory contents', async () => {
      const result = await executeTool('list_directory', {
        path: 'listdir',
        recursive: true
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      const names = result.output.entries.map(e => e.name);
      // Should include subdirectory contents with relative path
      const hasNestedFile = names.some(n => n.includes('c.txt'));
      assert.ok(hasNestedFile, 'Should include nested file c.txt');
    });

    it('pattern filtering works', async () => {
      const result = await executeTool('list_directory', {
        path: 'listdir',
        pattern: '*.txt'
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      const names = result.output.entries.map(e => e.name);
      assert.ok(names.includes('a.txt'));
      assert.ok(!names.includes('b.js'), 'Should not include b.js');
    });

    it('rejects path traversal', async () => {
      const result = await executeTool('list_directory', {
        path: '../../..'
      }, workspaceRoot);

      assert.strictEqual(result.success, false);
      assert.strictEqual(result.error.code, 'PATH_OUTSIDE_WORKSPACE');
    });
  });

  // -------------------------------------------------------------------------
  // run_command
  // -------------------------------------------------------------------------

  describe('run_command', () => {
    it('runs simple command and captures stdout', async () => {
      const result = await executeTool('run_command', {
        command: 'echo hello'
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      assert.strictEqual(result.output.stdout.trim(), 'hello');
      assert.strictEqual(result.output.timed_out, false);
    });

    it('captures stderr separately', async () => {
      const result = await executeTool('run_command', {
        command: 'echo error_msg 1>&2'
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      assert.ok(result.output.stderr.includes('error_msg'));
    });

    it('returns exit_code for failed commands', async () => {
      const result = await executeTool('run_command', {
        command: 'exit 1'
      }, workspaceRoot);

      assert.strictEqual(result.success, true); // Tool succeeds, command fails
      assert.strictEqual(result.output.exit_code, 1);
    });

    it('blocks dangerous commands', async () => {
      const result = await executeTool('run_command', {
        command: 'sudo rm -rf /'
      }, workspaceRoot);

      assert.strictEqual(result.success, false);
      assert.strictEqual(result.error.code, 'COMMAND_BLOCKED');
    });

    it('enforces timeout', async () => {
      const result = await executeTool('run_command', {
        command: 'node -e "setTimeout(()=>{}, 60000)"',
        timeout_ms: 500
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      assert.strictEqual(result.output.timed_out, true);
    }, { timeout: 15000 });
  });

  // -------------------------------------------------------------------------
  // search_files
  // -------------------------------------------------------------------------

  describe('search_files', () => {
    before(() => {
      // Create searchable files
      fs.mkdirSync(path.join(workspaceRoot, 'searchdir', 'sub'), { recursive: true });
      fs.writeFileSync(path.join(workspaceRoot, 'searchdir', 'hello.js'),
        'function hello() {\n  return "hello world";\n}\n');
      fs.writeFileSync(path.join(workspaceRoot, 'searchdir', 'data.txt'),
        'line one\nhello found here\nline three\n');
      fs.writeFileSync(path.join(workspaceRoot, 'searchdir', 'sub', 'nested.js'),
        'const x = "hello";\n');

      // Create node_modules (should be skipped)
      fs.mkdirSync(path.join(workspaceRoot, 'searchdir', 'node_modules'), { recursive: true });
      fs.writeFileSync(path.join(workspaceRoot, 'searchdir', 'node_modules', 'pkg.js'),
        'hello from node_modules\n');
    });

    it('finds pattern in files with file/line/content', async () => {
      const result = await executeTool('search_files', {
        pattern: 'hello',
        path: 'searchdir'
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      assert.ok(result.output.matches.length > 0);

      const match = result.output.matches[0];
      assert.ok('file' in match);
      assert.ok('line' in match);
      assert.ok('content' in match);
      assert.strictEqual(typeof match.line, 'number');
    });

    it('respects max_results limit', async () => {
      const result = await executeTool('search_files', {
        pattern: 'hello',
        path: 'searchdir',
        max_results: 1
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      assert.strictEqual(result.output.matches.length, 1);
      assert.strictEqual(result.output.truncated, true);
    });

    it('returns error for invalid regex', async () => {
      const result = await executeTool('search_files', {
        pattern: '(unclosed',
        path: 'searchdir'
      }, workspaceRoot);

      assert.strictEqual(result.success, false);
      assert.strictEqual(result.error.code, 'INVALID_REGEX');
    });

    it('skips node_modules directories', async () => {
      const result = await executeTool('search_files', {
        pattern: 'hello from node_modules',
        path: 'searchdir'
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      assert.strictEqual(result.output.matches.length, 0);
    });

    it('file_pattern filtering works', async () => {
      const result = await executeTool('search_files', {
        pattern: 'hello',
        path: 'searchdir',
        file_pattern: '*.js'
      }, workspaceRoot);

      assert.strictEqual(result.success, true);
      // Should find matches only in .js files, not .txt
      for (const match of result.output.matches) {
        assert.ok(match.file.endsWith('.js'), `Expected .js file, got ${match.file}`);
      }
      assert.ok(result.output.matches.length > 0);
    });
  });
});
