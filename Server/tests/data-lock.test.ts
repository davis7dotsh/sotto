import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { existsSync, mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { acquireDataDirectoryLock } from "../src/data-lock";

const directories: string[] = [];
function temporaryDirectory() {
  const directory = mkdtempSync(join(tmpdir(), "v07-lock-test-"));
  directories.push(directory);
  return directory;
}
afterEach(() => {
  for (const directory of directories.splice(0))
    rmSync(directory, { recursive: true, force: true });
});

describe("data directory ownership", () => {
  test("denies another descriptor for the same archive and allows independent archives", () => {
    const directory = temporaryDirectory();
    const first = acquireDataDirectoryLock(directory);
    try {
      expect(() => acquireDataDirectoryLock(directory)).toThrow("Another V07 server");
      const independent = acquireDataDirectoryLock(join(directory, "independent"));
      independent.release();
    } finally {
      first.release();
    }
    expect(existsSync(join(directory, ".server.lock"))).toBe(true);
    const next = acquireDataDirectoryLock(directory);
    next.release();
    next.release();
  });

  test("refuses symlinks without following them", () => {
    const directory = temporaryDirectory();
    const target = join(directory, "target");
    writeFileSync(target, "untouched");
    symlinkSync(target, join(directory, ".server.lock"));
    expect(() => acquireDataDirectoryLock(directory)).toThrow();
    expect(Bun.file(target).size).toBe(9);
  });

  test("refuses a directory as the lock", () => {
    const directory = temporaryDirectory();
    mkdirSync(join(directory, ".server.lock"));
    expect(() => acquireDataDirectoryLock(directory)).toThrow();
  });

  test("a Python flock process cannot acquire an archive owned by Bun", () => {
    const directory = temporaryDirectory();
    const lock = acquireDataDirectoryLock(directory);
    try {
      const result = Bun.spawnSync([
        "python3",
        "-c",
        `
import fcntl, os, sys
with open(os.path.join(sys.argv[1], '.server.lock'), 'a+') as file:
    try:
        fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        sys.exit(1)
    except BlockingIOError:
        print('busy')
`,
        directory,
      ]);
      expect(result.exitCode).toBe(0);
      expect(result.stdout.toString().trim()).toBe("busy");
    } finally {
      lock.release();
    }
  });

  test("spawned helpers do not inherit the archive lock descriptor", () => {
    const directory = temporaryDirectory();
    const lock = acquireDataDirectoryLock(directory);
    try {
      const result = Bun.spawnSync([
        "python3",
        "-c",
        `
import os, sys
lock = os.stat(os.path.join(sys.argv[1], '.server.lock'))
for descriptor in range(3, 1024):
    try:
        entry = os.fstat(descriptor)
    except OSError:
        continue
    if (entry.st_dev, entry.st_ino) == (lock.st_dev, lock.st_ino):
        sys.exit(1)
`,
        directory,
      ]);
      expect(result.exitCode).toBe(0);
    } finally {
      lock.release();
    }
  });
});

describe("cross-process and compiled locking", () => {
  const fixture = resolve(import.meta.dirname, "fixtures/lock-probe.ts");
  let compiledDirectory: string;
  let executable: string;
  beforeAll(async () => {
    compiledDirectory = mkdtempSync(join(tmpdir(), "v07-lock-binary-"));
    executable = join(compiledDirectory, "lock-probe");
    const result = await Bun.build({
      entrypoints: [fixture],
      compile: { outfile: executable, autoloadDotenv: false, autoloadBunfig: false },
    });
    expect(result.success).toBe(true);
  });
  afterAll(() => {
    if (compiledDirectory) rmSync(compiledDirectory, { recursive: true, force: true });
  });

  for (const compiled of [false, true]) {
    test(`Python ownership excludes the ${compiled ? "compiled binary" : "source process"}`, () => {
      const directory = temporaryDirectory();
      const command = compiled ? [executable, directory] : [process.execPath, fixture, directory];
      const result = Bun.spawnSync([
        "python3",
        "-c",
        `
import fcntl, os, subprocess, sys
with open(os.path.join(sys.argv[1], '.server.lock'), 'a+') as file:
    fcntl.flock(file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    result = subprocess.run(sys.argv[2:], capture_output=True, text=True)
    if result.returncode != 1 or 'Another V07 server' not in result.stderr:
        print(result.stdout, result.stderr)
        sys.exit(1)
`,
        directory,
        ...command,
      ]);
      expect(result.exitCode).toBe(0);
      const released = Bun.spawnSync(command);
      expect(released.exitCode).toBe(0);
      expect(released.stdout.toString().trim()).toBe("acquired");
    });

    test(`a crashed ${compiled ? "compiled binary" : "source process"} releases ownership`, async () => {
      const directory = temporaryDirectory();
      const command = compiled
        ? [executable, directory, "--hold"]
        : [process.execPath, fixture, directory, "--hold"];
      const child = Bun.spawn(command, { stdout: "pipe", stderr: "pipe" });
      try {
        const ready = await child.stdout.getReader().read();
        expect(new TextDecoder().decode(ready.value)).toContain("acquired");
        expect(() => acquireDataDirectoryLock(directory)).toThrow("Another V07 server");
      } finally {
        child.kill("SIGKILL");
        await child.exited;
      }
      const lock = acquireDataDirectoryLock(directory);
      lock.release();
    });
  }
});
