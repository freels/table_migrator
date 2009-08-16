require 'rubygems'
require 'shoulda'
require 'active_record'

TEST_ROOT = File.expand_path(File.dirname(__FILE__))
PLUGIN_ROOT = File.expand_path(TEST_ROOT, '..')

$: << File.join(TEST_ROOT, 'lib')

load 'database.rb'


