#!/bin/sh
set -eu

exec bundle exec puma -C config/puma.rb
