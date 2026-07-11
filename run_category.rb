# Runs one ruby/spec category against monoruby and writes an mspec-style
# YAML summary. Called from the CI workflow once per category so each
# category's wall time shows up on its own step in the Actions UI.
#
# Strategy per category:
#   - core, library: per-file via run_specs.rb. core has to run per-file
#     because monoruby doesn't kill background threads left over from spec
#     files at process exit — a whole-category `mspec run` gets stuck in
#     the summary phase and times out. library stays per-file so its many
#     `require` failures are clamped per-file (an aggregate clamp would
#     collapse the pass rate to 0%).
#   - everything else: one `mspec run` over the skip-list-filtered file
#     list. If that dies without producing yaml (a new hang not in the
#     skip list), fall back to per-file so the category is still measured.
#
# Usage: ruby run_category.rb <category>
# Env:   SPEC_SKIP_FILE   fixed-string skip list, one path per line
#        SPEC_TIMEOUT     per-file timeout (passed through to run_specs.rb)
#        SPEC_JOBS        parallel per-file workers (passed through)

require 'yaml'
require 'set'

category = ARGV[0] or abort 'usage: ruby run_category.rb <category>'

MSPEC    = 'spec/mspec/bin/mspec'
TARGET   = 'monoruby'
OUT      = "rubyspec-stats/monoruby/#{category}.yml"
PER_FILE = %w[core library].freeze
RUN_SPECS = File.join(__dir__, 'run_specs.rb')

if PER_FILE.include?(category)
  exec 'ruby', RUN_SPECS, MSPEC, TARGET, "spec/ruby/#{category}", OUT
end

skip_file = ENV['SPEC_SKIP_FILE']
skip = skip_file && File.exist?(skip_file) ?
  File.readlines(skip_file, chomp: true).reject(&:empty?).to_set : Set.new
files = Dir["spec/ruby/#{category}/**/*_spec.rb"].sort.reject { |f| skip.include?(f) }

File.write(OUT, '')
system('timeout', '300', MSPEC, 'run', '-t', TARGET,
       '--format', 'yaml', '--output', OUT, *files, in: File::NULL)

if File.size?(OUT).to_i > 0
  # Strip the per-failure `exceptions` list (it would bloat the committed yaml)
  # and clamp examples >= failures+errors+tagged so `passing` stays non-negative
  # if a fresh load-error imbalance survives.
  d = YAML.load_file(OUT)
  counted = d['failures'].to_i + d['errors'].to_i + d['tagged'].to_i
  d['examples'] = [d['examples'].to_i, counted].max
  d['exceptions'] = nil
  File.write(OUT, d.to_yaml)
else
  warn "::warning::mspec run for #{category} produced no yaml; falling back to per-file"
  exec 'ruby', RUN_SPECS, MSPEC, TARGET, "spec/ruby/#{category}", OUT
end
