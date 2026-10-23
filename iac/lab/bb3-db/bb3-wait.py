import os
import shutil
import signal
import subprocess
import sys
import time


def elapsed_text(seconds):
    hours, remainder = divmod(max(0, int(seconds)), 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def run_wait(label, command, stream=None, clock=None):
    stream = sys.stderr if stream is None else stream
    clock = time.monotonic if clock is None else clock
    interactive = stream.isatty()
    started = clock()
    child = None
    previous_width = 0
    exit_code = 127

    def display(result=None):
        nonlocal previous_width
        elapsed = elapsed_text(clock() - started)
        shown_label = label
        suffix = f" | elapsed {elapsed}"
        if result is not None:
            suffix += f" | {result}"
        if interactive:
            width = max(1, shutil.get_terminal_size((80, 24)).columns - 1)
            label_width = max(0, width - len(suffix))
            if len(shown_label) > label_width:
                shown_label = (shown_label[:max(0, label_width - 3)] + "...")[:label_width]
        line = shown_label + suffix
        if interactive:
            line = line[-width:]
            stream.write("\r" + line.ljust(min(previous_width, width)))
            previous_width = len(line)
            if result is not None:
                stream.write("\n")
        else:
            stream.write(line + "\n")
        stream.flush()

    try:
        display()
        child = subprocess.Popen(["bash", "-c", '"$@"', "bb3-wait", *command],
                                 start_new_session=True)
        while True:
            try:
                exit_code = child.wait(timeout=1)
                break
            except subprocess.TimeoutExpired:
                if interactive:
                    display()
    except KeyboardInterrupt:
        exit_code = 130
    except OSError:
        print("Could not start wait command; arguments withheld.", file=stream)
    finally:
        if child is not None and child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
                try:
                    child.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(child.pid, signal.SIGKILL)
                    child.wait()
            except ProcessLookupError:
                pass
        if exit_code < 0:
            exit_code = 128 - exit_code
        display("complete" if exit_code == 0 else f"stopped (exit {exit_code})")
    return exit_code


def main(arguments):
    if len(arguments) < 2:
        print("Usage: bb3-wait.py LABEL COMMAND [ARGUMENT ...]", file=sys.stderr)
        return 2

    def interrupt_wait(signum, frame):
        raise KeyboardInterrupt

    signal.signal(signal.SIGTERM, interrupt_wait)
    signal.signal(signal.SIGHUP, interrupt_wait)
    return run_wait(arguments[0], arguments[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))