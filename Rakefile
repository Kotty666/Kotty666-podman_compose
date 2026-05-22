# frozen_string_literal: true

# load optional tasks for tests
# only available if gem group test is installed
begin
  require 'voxpupuli/test/rake'
rescue LoadError
end

# load optional tasks for releases
# only available if gem group releases is installed
begin
  require 'voxpupuli/release/rake_tasks'
rescue LoadError
end

desc 'Auto-correct rubocop issues and run syntax/lint/metadata_lint/check:symlinks/check:git_ignore/check:dot_underscore/check:test_file/rubocop'
task test: [
  :syntax,
  :lint,
  :metadata_lint,
  'check:symlinks',
  'check:git_ignore',
  'check:dot_underscore',
  'check:test_file',
  :rubocop,
  :spec,
]
