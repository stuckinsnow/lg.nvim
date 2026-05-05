#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building lg-mcp..."
cd mcp && go build -o lg-mcp . && cd ..

echo "Building lg-git-mcp..."
cd git-mcp && go build -o lg-git-mcp . && cd ..

echo "Building lg-hint-mcp..."
cd hint-mcp && go build -o lg-hint-mcp . && cd ..

echo "Building lg-lsp..."
cd lsp && go build -o lg-lsp . && cd ..

echo "Building lg-acp..."
cd acp && go build -o lg-acp . && cd ..

echo "Building lg-tap..."
cd tap && go build -o lg-tap . && cd ..

echo "Done."
