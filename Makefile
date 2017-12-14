
dev-server:
	RACK_ENV=development rbenv exec bundle exec ruby ./irmagi.rb /dev/irmagi server 5555

setup:
	rbenv exec bundle install --path vendor/bundler --binstubs
