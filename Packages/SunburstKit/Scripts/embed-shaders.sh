#!/bin/sh
# Writes Sources/SunburstKit/ShaderSource.swift from Sources/SunburstKit/Shaders.metal, so the shaders are built into the
# package and an app that uses it needs no resource of its own. Run it after changing Shaders.metal; a test fails until you do.
set -e
cd "$(dirname "$0")/.."
OUT=Sources/SunburstKit/ShaderSource.swift
{
  echo "// Made by Scripts/embed-shaders.sh from Shaders.metal. Change that file and run the script, not this one."
  echo ""
  echo "enum ShaderSource {"
  echo "    static let metal = #\"\"\""
  cat Sources/SunburstKit/Shaders.metal
  echo "\"\"\"#"
  echo "}"
} > "$OUT"
echo "wrote $OUT"
