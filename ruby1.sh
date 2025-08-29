#!/bin/bash
set -e

echo "===== Installing Ruby 3.1.6 via rbenv ====="

# Dependencies
sudo apt-get update -y
sudo apt-get install -y git build-essential libssl-dev libreadline-dev zlib1g-dev

# rbenv setup
if [ ! -d "$HOME/.rbenv" ]; then
  git clone https://github.com/rbenv/rbenv.git ~/.rbenv
  echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
  echo 'eval "$(rbenv init -)"' >> ~/.bashrc
  export PATH="$HOME/.rbenv/bin:$PATH"
  eval "$(rbenv init -)"
fi

# ruby-build plugin
if [ ! -d "$HOME/.rbenv/plugins/ruby-build" ]; then
  git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
fi

# Install Ruby 3.1.6
~/.rbenv/bin/rbenv install -s 3.1.6
~/.rbenv/bin/rbenv global 3.1.6

# Refresh shell
export PATH="$HOME/.rbenv/shims:$PATH"

# Verify
ruby -v

# Install Bundler
gem install bundler --no-document
bundle -v

echo "===== Ruby 3.1.6 + Bundler installed successfully ====="
