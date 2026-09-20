"""Let MCP 1.6 stdio servers decline modern discovery before legacy initialization."""

import argparse
from contextlib import asynccontextmanager
import importlib
from importlib.metadata import version
from pathlib import Path
import runpy
import sys

import anyio
import mcp.types as types
from stdio_shutdown import install_eof_shutdown, run_cli


@asynccontextmanager
async def compatible_stdio_server(original_transport, *args, **kwargs):
    """Reply only to unsupported server/discover; preserve all other frames."""
    async with original_transport(*args, **kwargs) as (incoming, outgoing):
        sender, receiver = anyio.create_memory_object_stream(0)

        async def receive_messages():
            async with sender:
                async for message in incoming:
                    if (
                        isinstance(message, types.JSONRPCMessage)
                        and isinstance(message.root, types.JSONRPCRequest)
                        and message.root.method == "server/discover"
                    ):
                        await outgoing.send(types.JSONRPCMessage(types.JSONRPCError(
                            jsonrpc="2.0",
                            id=message.root.id,
                            error=types.ErrorData(code=-32601, message="Method not found"),
                        )))
                    else:
                        await sender.send(message)

        async with receiver, anyio.create_task_group() as tasks:
            tasks.start_soon(receive_messages)
            try:
                yield receiver, outgoing
            finally:
                tasks.cancel_scope.cancel()


def install_compatibility():
    """Change this process's transport aliases, never installed package files."""
    installed_version = version("mcp")
    if installed_version != "1.6.0":
        raise RuntimeError(
            f"This compatibility entry requires the verified mcp==1.6.0 environment; got {installed_version}"
        )
    install_eof_shutdown()
    stdio = importlib.import_module("mcp.server.stdio")
    fastmcp = importlib.import_module("mcp.server.fastmcp.server")
    original_transport = stdio.stdio_server

    def transport(*args, **kwargs):
        return compatible_stdio_server(original_transport, *args, **kwargs)

    stdio.stdio_server = transport
    fastmcp.stdio_server = transport


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--script", type=Path, required=True)
    parser.add_argument("script_args", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    script = options.script.resolve(strict=True)
    arguments = options.script_args
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    install_compatibility()
    sys.argv = [str(script), *arguments]
    runpy.run_path(str(script), run_name="__main__")


if __name__ == "__main__":
    run_cli(main)
