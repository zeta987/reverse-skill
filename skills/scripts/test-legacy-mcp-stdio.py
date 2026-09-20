"""Check the MCP 1.6 discovery compatibility boundary without a model or backend."""
from contextlib import asynccontextmanager
import importlib.util
from pathlib import Path
import sys
import unittest

import anyio
import mcp.types as types

SCRIPT = Path(__file__).parent / "mcp" / "legacy-mcp-stdio.py"
sys.path.insert(0, str(SCRIPT.parent))
spec = importlib.util.spec_from_file_location("legacy_mcp_stdio", SCRIPT)
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)


class CompatibilityTests(unittest.TestCase):
    def test_discovery_error_and_unchanged_legacy_messages(self):
        async def check():
            incoming_send, incoming_receive = anyio.create_memory_object_stream(5)
            outgoing_send, outgoing_receive = anyio.create_memory_object_stream(5)

            @asynccontextmanager
            async def transport():
                yield incoming_receive, outgoing_send

            discover = types.JSONRPCMessage(types.JSONRPCRequest(
                jsonrpc="2.0", id="probe-1", method="server/discover", params={}))
            initialize = types.JSONRPCMessage(types.JSONRPCRequest(
                jsonrpc="2.0", id=2, method="initialize", params={"protocolVersion": "2024-11-05"}))
            notification = types.JSONRPCMessage(types.JSONRPCNotification(
                jsonrpc="2.0", method="notifications/initialized"))
            invalid_frame = ValueError("invalid JSON frame")
            async with compat.compatible_stdio_server(transport) as (read, write):
                self.assertIs(write, outgoing_send)
                await incoming_send.send(discover)
                with anyio.fail_after(2):
                    error = (await outgoing_receive.receive()).root
                self.assertIsInstance(error, types.JSONRPCError)
                self.assertEqual(error.id, "probe-1")
                self.assertEqual(error.error.code, -32601)
                for message in (initialize, notification, invalid_frame):
                    await incoming_send.send(message)
                    with anyio.fail_after(2):
                        self.assertIs(await read.receive(), message)
                response = types.JSONRPCMessage(types.JSONRPCResponse(
                    jsonrpc="2.0", id=2, result={"protocolVersion": "2024-11-05"}))
                await write.send(response)
                self.assertIs(await outgoing_receive.receive(), response)
            await incoming_send.aclose()
            await outgoing_receive.aclose()

        anyio.run(check)


if __name__ == "__main__":
    unittest.main()
