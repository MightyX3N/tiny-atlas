#!/bin/sh
# Gets what VoxTrainer needs that isn't kept in the repo:
#  - VoxBox (git submodule)
#  - Lua GDExtension with LuaJIT 0.8.2 (MIT, gilzoide/lua-gdextension) into addons/
#  - omniplay_ble.dll, the Windows Bluetooth helper, built from native/omniplay_ble.c (needs mingw-w64)
set -e
cd "$(dirname "$0")/.."

git submodule update --init --recursive

LUA_VER=0.8.2
if [ ! -f addons/lua-gdextension/luagdextension.gdextension ]; then
  echo "Lua GDExtension $LUA_VER (LuaJIT)..."
  mkdir -p build
  curl -sSfL -o build/lua-gdextension.zip \
    "https://github.com/gilzoide/lua-gdextension/releases/download/$LUA_VER/lua-gdextension%2Bluajit.zip"
  unzip -qo build/lua-gdextension.zip "addons/*" -d .
fi

if command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
  echo "omniplay_ble.dll..."
  mkdir -p build
  x86_64-w64-mingw32-gcc -shared -O2 -Wall -o build/omniplay_ble.dll native/omniplay_ble.c \
    -lruntimeobject -lole32 -lws2_32 -static-libgcc -static
else
  echo "mingw-w64 not found: skipping omniplay_ble.dll (only needed for Bluetooth on Windows)"
fi
echo "done"
