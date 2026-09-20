"""Narrow launch-time adapters for the tested legacy FastMCP bridges."""
import ast
import builtins
from pathlib import Path
import sys
from types import ModuleType
from typing import Annotated

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.server import Settings
from pydantic import Field

REGISTER_TYPE = '_reverse_mcp_register_arg'


def _parameters(function):
    arguments = function.args
    if arguments.posonlyargs or arguments.kwonlyargs or arguments.vararg or arguments.kwarg:
        return None
    return [argument.arg for argument in arguments.args]


def _posts_to(function, endpoint):
    return any(
        isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
        and node.func.id == 'safe_post' and len(node.args) >= 2
        and isinstance(node.args[1], ast.Constant) and node.args[1].value == endpoint
        for node in ast.walk(function)
    )


def adapt_ghydra(tree):
    """Drop only the known obsolete duplicate; retain the real /analysis/run tool."""
    definitions = [node for node in tree.body
                   if isinstance(node, ast.FunctionDef) and node.name == 'analysis_run']
    if len(definitions) <= 1:
        return
    if (len(definitions) != 2
            or _parameters(definitions[0]) != ['port', 'analysis_options']
            or _parameters(definitions[1]) != ['background', 'port']
            or not _posts_to(definitions[0], 'analysis')
            or not _posts_to(definitions[1], 'analysis/run')):
        raise RuntimeError('Unknown duplicate analysis_run definitions; inspect this bridge version before adapting it.')
    tree.body.remove(definitions[0])


class _RegisterReferences(ast.NodeTransformer):
    def visit_Name(self, node):
        if node.id == 'register':
            node.id = 'register_name'
        return node


def adapt_x64dbg(tree):
    """Use an internal parameter alias while preserving the public register key."""
    for function in tree.body:
        if not isinstance(function, ast.FunctionDef) or function.name not in ('RegisterGet', 'RegisterSet'):
            continue
        names = _parameters(function)
        expected = ['register'] + (['value'] if function.name == 'RegisterSet' else [])
        if names != expected:
            raise RuntimeError(f'Unknown {function.name} signature; inspect this bridge version before adapting it.')
        if any(isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.Lambda, ast.ClassDef))
               for statement in function.body for node in ast.walk(statement)):
            raise RuntimeError(f'Nested scope in {function.name}; automatic parameter adaptation is unsafe.')
        if any(isinstance(node, ast.Name) and node.id == 'register_name' for node in ast.walk(function)):
            raise RuntimeError(f'Internal alias already used by {function.name}.')
        argument = function.args.args[0]
        argument.arg = 'register_name'
        argument.annotation = ast.copy_location(ast.Name(id=REGISTER_TYPE, ctx=ast.Load()), argument)
        for statement in function.body:
            _RegisterReferences().visit(statement)


def _diagnostic_print(*values, **kwargs):
    kwargs.setdefault('file', sys.stderr)
    builtins.print(*values, **kwargs)


def run_bridge(path, adapter, arguments=(), redirect_print=False):
    """Execute adapted source in memory, retaining its filename and CLI arguments."""
    bridge = Path(path).resolve(strict=True)
    tree = ast.parse(bridge.read_text(encoding='utf-8-sig'), filename=str(bridge))
    if any(isinstance(node, ast.Name) and node.id == REGISTER_TYPE for node in ast.walk(tree)):
        raise RuntimeError('Bridge source uses the reserved compatibility annotation name.')
    adapter(tree)
    ast.fix_missing_locations(tree)
    # Resolve forward references before BaseSettings sources inspect FieldInfo.
    Settings.model_rebuild(_types_namespace={'FastMCP': FastMCP})
    module = ModuleType('__main__')
    module.__dict__.update({
        '__file__': str(bridge), '__package__': '', '__spec__': None,
        '__cached__': None, REGISTER_TYPE: Annotated[str, Field(alias='register')],
    })
    if redirect_print:
        module.__dict__['print'] = _diagnostic_print
    previous_main = sys.modules.get('__main__')
    previous_argv = sys.argv
    previous_path = sys.path[:]
    try:
        sys.modules['__main__'] = module
        sys.argv = [str(bridge), *arguments]
        sys.path.insert(0, str(bridge.parent))
        exec(compile(tree, str(bridge), 'exec'), module.__dict__)
    finally:
        if previous_main is None:
            sys.modules.pop('__main__', None)
        else:
            sys.modules['__main__'] = previous_main
        sys.argv = previous_argv
        sys.path[:] = previous_path
