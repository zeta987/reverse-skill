"""Graceful local shutdown for the tested MCP 1.6 bridge entrypoints."""
from importlib.metadata import version


def install_eof_shutdown():
    """Let the MCP 1.6 server loop observe completion of its transport reader."""
    if version('mcp') != '1.6.0':
        return
    from mcp.server.session import ServerSession

    original = ServerSession._receive_loop
    if getattr(original, '_reverse_skill_eof_shutdown', False):
        return

    async def receive_loop(self):
        try:
            await original(self)
        finally:
            # In 1.6 this sender closes only in __aexit__, but Server.run waits
            # on its receiver before it can enter __aexit__. close() is sync,
            # idempotent, and remains safe while the task is being cancelled.
            self._incoming_message_stream_writer.close()

    receive_loop._reverse_skill_eof_shutdown = True
    ServerSession._receive_loop = receive_loop


def run_cli(main):
    """Keep explicit user interruption quiet after normal stack unwinding."""
    try:
        main()
    except KeyboardInterrupt:
        raise SystemExit(130) from None
