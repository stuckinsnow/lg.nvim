#!/bin/bash
set -e

cd "$(dirname "$0")"

echo "Building lg-mcp..."
cd mcp && go build -o lg-mcp . && cd ..

echo "Building lg-git-mcp..."
cd mcp/git-mcp && go build -o lg-git-mcp . && cd ../..

echo "Building lg-hint-mcp..."
cd mcp/hint-mcp && go build -o lg-hint-mcp . && cd ../..

echo "Building lg-lsp..."
cd lsp && go build -o lg-lsp . && cd ..

echo "Done."
