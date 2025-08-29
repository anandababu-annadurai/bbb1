sudo apt-get update -y
sudo apt-get install -y git build-essential libssl-dev libreadline-dev zlib1g-dev

# Install rbenv
git clone https://github.com/rbenv/rbenv.git ~/.rbenv
echo 'export PATH="$HOME/.rbenv/bin:$PATH"' >> ~/.bashrc
echo 'eval "$(rbenv init -)"' >> ~/.bashrc
source ~/.bashrc

# Add ruby-build plugin
git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build

# Install Ruby 3.1.6
rbenv install 3.1.6
rbenv global 3.1.6

# Verify
ruby -v

# Install Bundler
gem install bundler --no-document
bundle -v
