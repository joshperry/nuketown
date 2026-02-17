"""Entry point for nuketown-daemon."""

import asyncio
import logging
import signal

from .daemon import Daemon

log = logging.getLogger("nuketown")


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(name)s %(levelname)s %(message)s",
    )
    log.info("nuketown-daemon starting")

    loop = asyncio.new_event_loop()

    shutdown_event = asyncio.Event()

    def _signal_handler() -> None:
        log.info("received shutdown signal")
        shutdown_event.set()

    for sig in (signal.SIGTERM, signal.SIGINT):
        loop.add_signal_handler(sig, _signal_handler)

    daemon = Daemon()

    try:
        loop.run_until_complete(daemon.run(shutdown_event))
    finally:
        loop.close()

    log.info("nuketown-daemon stopped")


if __name__ == "__main__":
    main()
