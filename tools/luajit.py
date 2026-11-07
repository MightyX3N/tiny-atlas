"""Run a Lua file in LuaJIT 2.1 (the Lua GMod and LOVE use) with command-line args: luajit.py FILE [args...]
Uses lupa's bundled LuaJIT, so no luajit binary is needed."""
import os, sys
from lupa import luajit21 as lupa
L = lupa.LuaRuntime(unpack_returned_tuples=True)
path = os.path.abspath(sys.argv[1])
L.execute('io.stdout:setvbuf("line")')
L.globals().arg = L.table_from(sys.argv[2:])
L.execute(f'package.path = [[{os.path.dirname(path)}/?.lua;]] .. package.path')
rc = L.execute(f'local f = assert(loadfile([[{path}]])); return f(unpack(arg))')
sys.exit(0 if rc in (None, True, 0) else (rc if isinstance(rc, int) else 1))
