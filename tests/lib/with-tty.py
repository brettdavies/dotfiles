#!/usr/bin/env python3
"""Runs a command with a pseudo-terminal as its controlling terminal, typing a line into it.

Usage: python3 -I with-tty.py <line> <command> [<argument>...]

The command's own stdout and stderr are the terminal too, so a caller that wants them separate redirects them inside the
command. The line waits in the terminal's input queue until the command reads /dev/tty. Exits with the command's status.
"""
import os
import pty
import sys


def main() -> int:
    line, argv = sys.argv[1], sys.argv[2:]
    pid, master = pty.fork()
    if pid == 0:
        os.execvp(argv[0], argv)
    os.write(master, (line + "\n").encode())
    while True:
        try:
            if not os.read(master, 4096):
                break
        except OSError:
            break
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
