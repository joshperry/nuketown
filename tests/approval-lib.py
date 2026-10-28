# Shared helpers for the approval VM tests (prepended to each testScript).

import json


def setup():
    machine.wait_for_unit("multi-user.target")
    machine.wait_for_unit("nuketown-broker.service", user="human")
    machine.wait_for_file("/run/nuketown-broker/socket")
    machine.succeed(
        "mkdir -p /tmp/prompts && chmod 1777 /tmp/prompts",
        "echo deny > /tmp/prompter-answer && chmod 644 /tmp/prompter-answer",
        "echo ok > /tmp/reviewer-mode && chmod 644 /tmp/reviewer-mode",
    )


def as_user(user, cmd, path="/tmp/as-user.sh"):
    """Shell command that runs cmd (bash) as user, from a script file so
    cmd needs no extra quoting. Runs in the user's home."""
    machine.succeed(f"cat > {path} <<'EOF'\n{cmd}\nEOF\nchmod 755 {path}")
    return f"su - {user} -s /bin/sh -c 'bash {path}'"


def as_ada(cmd):
    return as_user("ada", cmd)


def answer(a):
    machine.succeed(f"echo {a} > /tmp/prompter-answer")


def prompt_count():
    return int(machine.succeed("ls /tmp/prompts | wc -l").strip())


def last_prompt():
    n = prompt_count()
    assert n > 0, "no prompt recorded"
    req = json.loads(machine.succeed(f"cat /tmp/prompts/{n}/request.json"))
    rev = json.loads(machine.succeed(f"cat /tmp/prompts/{n}/review.json"))
    return n, req, rev
