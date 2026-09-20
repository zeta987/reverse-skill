"""Exercise bridge compatibility through real MCP stdio, without a debugger."""
import asyncio
from datetime import timedelta
import json
from pathlib import Path
import sys
import tempfile
import textwrap
import unittest

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

ROOT = Path(__file__).resolve().parents[2]
LAUNCHERS = ROOT / 'skills' / 'scripts' / 'mcp'

GHYDRA = '''
import warnings
from mcp.server.fastmcp import FastMCP
mcp = FastMCP('ghydra-fixture')
def safe_post(port, endpoint, data):
    return {'port': port, 'endpoint': endpoint, 'data': data}
@mcp.tool()
def analysis_run(port: int = None, analysis_options: dict = None) -> dict:
    return safe_post(port, 'analysis', analysis_options or {})
@mcp.tool()
def analysis_run(background: bool = True, port: int = None) -> dict:
    return safe_post(port, 'analysis/run', {'background': str(background).lower()})
print('fixture diagnostic')
warnings.warn('unrelated warning remains visible', UserWarning)
if __name__ == '__main__':
    mcp.run(transport='stdio')
'''

X64DBG = '''
import sys
from mcp.server.fastmcp import FastMCP
mcp = FastMCP('x64dbg-fixture')
def safe_get(endpoint, params):
    return {'endpoint': endpoint, 'params': params}
@mcp.tool()
def RegisterGet(register: str) -> dict:
    return safe_get('Register/Get', {'register': register})
@mcp.tool()
def RegisterSet(register: str, value: str) -> dict:
    return safe_get('Register/Set', {'register': register, 'value': value})
if __name__ == '__main__':
    assert sys.argv[1:] == ['serve'], sys.argv
    mcp.run(transport='stdio')
'''


async def exercise(launcher, source, calls, legacy=False):
    # Windows may briefly retain the inherited stderr handle after SDK disposal.
    with tempfile.TemporaryDirectory(prefix='reverse-mcp-compat-', ignore_cleanup_errors=True) as folder:
        bridge = Path(folder) / 'fixture.py'
        bridge.write_text(textwrap.dedent(source), encoding='utf-8')
        error_path = Path(folder) / 'stderr.txt'
        args = [str(LAUNCHERS / launcher), '--bridge', str(bridge)]
        if legacy:
            args = [str(LAUNCHERS / 'legacy-mcp-stdio.py'), '--script', args[0], '--', *args[1:]]
        params = StdioServerParameters(command=sys.executable, args=args,
                                       env={'PYTHONWARNINGS': 'always'})
        with error_path.open('w', encoding='utf-8') as errors:
            async with stdio_client(params, errlog=errors) as (read, write):
                async with ClientSession(read, write, read_timeout_seconds=timedelta(seconds=10)) as session:
                    await session.initialize()
                    tools = await session.list_tools()
                    results = [await session.call_tool(name, arguments) for name, arguments in calls]
        return tools.tools, results, error_path.read_text(encoding='utf-8')


def result_dict(result):
    assert not result.isError, result
    return json.loads(result.content[0].text)


class BridgeCompatibilityTests(unittest.TestCase):
    def test_legacy_discovery_wrapper_composes_with_both_launchers(self):
        for launcher, source, tool, arguments, expected in [
            ('ghydra-stdio.py', GHYDRA, 'analysis_run', {'background': False},
             {'port': None, 'endpoint': 'analysis/run', 'data': {'background': 'false'}}),
            ('x64dbg-stdio.py', X64DBG, 'RegisterGet', {'register': 'rax'},
             {'endpoint': 'Register/Get', 'params': {'register': 'rax'}}),
        ]:
            with self.subTest(launcher=launcher):
                _, results, errors = asyncio.run(exercise(launcher, source, [(tool, arguments)], legacy=True))
                self.assertEqual(result_dict(results[0]), expected)
                self.assertNotIn('IncompleteFieldDefinitionWarning', errors)
                self.assertNotIn('shadows an attribute', errors)
                self.assertNotIn('Tool already exists: analysis_run', errors)

    def test_startup_resolves_lifespan_before_settings_sources_read_it(self):
        _, _, errors = asyncio.run(exercise('ghydra-stdio.py', '''
from mcp.server.fastmcp import FastMCP
mcp = FastMCP('startup-fixture')
if __name__ == '__main__':
    mcp.run(transport='stdio')
''', []))
        self.assertNotIn('IncompleteFieldDefinitionWarning', errors)

    def test_ghydra_uses_supported_analysis_endpoint_without_duplicate_or_lifespan_warning(self):
        tools, results, errors = asyncio.run(exercise('ghydra-stdio.py', GHYDRA, [
            ('analysis_run', {'background': False, 'port': 8192}),
            ('analysis_run', {}),
        ]))
        analysis = [tool for tool in tools if tool.name == 'analysis_run']
        self.assertEqual(len(analysis), 1)
        self.assertEqual(set(analysis[0].inputSchema['properties']), {'background', 'port'})
        self.assertEqual(result_dict(results[0]), {'port': 8192, 'endpoint': 'analysis/run', 'data': {'background': 'false'}})
        self.assertEqual(result_dict(results[1])['data'], {'background': 'true'})
        self.assertNotIn('Tool already exists:', errors)
        self.assertNotIn('IncompleteFieldDefinitionWarning', errors)
        self.assertIn('fixture diagnostic', errors)
        self.assertIn('unrelated warning remains visible', errors)

    def test_x64dbg_preserves_register_schema_and_backend_keys_without_shadow_warning(self):
        tools, results, errors = asyncio.run(exercise('x64dbg-stdio.py', X64DBG, [
            ('RegisterGet', {'register': 'rax'}),
            ('RegisterSet', {'register': 'rax', 'value': '0x1234'}),
            ('RegisterGet', {}),
        ]))
        by_name = {tool.name: tool for tool in tools}
        self.assertEqual(set(by_name['RegisterGet'].inputSchema['properties']), {'register'})
        self.assertEqual(set(by_name['RegisterSet'].inputSchema['properties']), {'register', 'value'})
        self.assertEqual(result_dict(results[0]), {'endpoint': 'Register/Get', 'params': {'register': 'rax'}})
        self.assertEqual(result_dict(results[1]), {'endpoint': 'Register/Set', 'params': {'register': 'rax', 'value': '0x1234'}})
        self.assertTrue(results[2].isError)
        self.assertNotIn('shadows an attribute', errors)
        self.assertNotIn('IncompleteFieldDefinitionWarning', errors)


if __name__ == '__main__':
    unittest.main()
