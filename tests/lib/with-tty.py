#!/usr/bin/env python3
"""Runs a command with a pseudo-terminal as its controlling terminal, typing a line into it.

Usage: python3 -I with-tty.py <line> <command> [<argument>...]

The command's own stdout and stderr are the terminal too, so a caller that wants them separate redirects them inside the
command. The line waits in the terminal's input queue until the command reads /dev/tty. What the command writes to the
terminal is copied to stdout. Exits with the command's status.
"""
import os
import pty
import sys


def main() -> int:
    line, argv = sys.argv[1], sys.argv[2:]
    pid, master = pty.fork()
    if pid == 0:
        # A command that exits at once can lose its last writes to the terminal, so the shell holds the terminal open for a
        # moment after it.
        os.execvp("bash", ["bash", "-c", '"$@"; rc=$?; sleep 0.3; exit $rc', "_", *argv])
    os.write(master, (line + "\n").encode())
    while True:
        try:
            data = os.read(master, 4096)
            if not data:
                break
            sys.stdout.buffer.write(data)
            sys.stdout.flush()
        except OSError:
            break
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
