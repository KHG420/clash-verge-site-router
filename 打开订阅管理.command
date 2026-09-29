#!/bin/sh
cd "$(dirname "$0")" || exit 1
exec ./bin/verge-router web --open
