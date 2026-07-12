# Runs one ruby/spec category against monoruby and writes an mspec-style
# YAML summary. Called from the CI workflow once per category so each
# category's wall time shows up on its own step in the Actions UI.
#
# Strategy per category:
#   - core, library: partition the first-level sub-directories. Any sub-dir
#     with a file in the skip list is treated as "hang-prone" and runs
#     per-file via run_specs.rb; the rest run in one mspec process. Whole-
#     category `mspec run` on these is unsafe — monoruby doesn't kill
#     background threads left over from spec files at process exit, so a
#     run that includes anything under core/thread, core/mutex, ... gets
#     stuck in the summary phase. This split keeps the fast path fast and
#     confines per-file overhead to the few sub-dirs that actually need it.
#   - everything else: one `mspec run` over the skip-list-filtered file
#     list. If it dies without producing yaml (a new hang), fall back to
#     per-file so the category is still measured.
#
# Usage: ruby run_category.rb <category>
# Env:   SPEC_SKIP_FILE   fixed-string skip list, one path per line
#        SPEC_TIMEOUT     per-file timeout (passed through to run_specs.rb)
#        SPEC_JOBS        parallel per-file workers (passed through)

require 'yaml'
require 'set'

category = ARGV[0] or abort 'usage: ruby run_category.rb <category>'

MSPEC     = 'spec/mspec/bin/mspec'
TARGET    = 'monoruby'
OUT       = "rubyspec-stats/monoruby/#{category}.yml"
TMP       = "#{OUT}.tmp"
RUN_SPECS = File.join(__dir__, 'run_specs.rb')
PER_FILE_CATEGORIES = %w[core library].freeze

skip_file = ENV['SPEC_SKIP_FILE']
SKIP = skip_file && File.exist?(skip_file) ?
  File.readlines(skip_file, chomp: true).reject(&:empty?).to_set : Set.new

def new_totals
  { 'files'        => 0,
    'examples'     => 0,
    'expectations' => 0,
    'failures'     => 0,
    'errors'       => 0,
    'tagged'       => 0,
    'time'         => 0.0 }
end

def load_yaml(path)
  return nil unless File.exist?(path) && File.size?(path).to_i > 0
  YAML.load_file(path) rescue nil
end

def run_mspec(out, files)
  return nil if files.empty?
  File.write(out, '')
  system('timeout', '300', MSPEC, 'run', '-t', TARGET,
         '--format', 'yaml', '--output', out, *files, in: File::NULL)
  load_yaml(out)
end

def run_per_file(spec_dir, out)
  system('ruby', RUN_SPECS, MSPEC, TARGET, spec_dir, out)
  load_yaml(out)
end

# Clamp examples >= failures+errors+tagged so `passing` stays non-negative
# when mspec's error counter picks up example-external exceptions
# (spec-file load failures, `before(:all)` hooks, ...). run_specs.rb already
# clamps per file, so re-clamping its aggregate is idempotent.
def aggregate(totals, data)
  return unless data
  counted  = data['failures'].to_i + data['errors'].to_i + data['tagged'].to_i
  examples = [data['examples'].to_i, counted].max
  totals['files']        += data['files'].to_i
  totals['examples']     += examples
  totals['expectations'] += data['expectations'].to_i
  totals['failures']     += data['failures'].to_i
  totals['errors']       += data['errors'].to_i
  totals['tagged']       += data['tagged'].to_i
  totals['time']         += data['time'].to_f
end

totals = new_totals

if PER_FILE_CATEGORIES.include?(category)
  cat_dir = "spec/ruby/#{category}"
  subdirs = Dir.children(cat_dir).select { |d| File.directory?(File.join(cat_dir, d)) }
  hang_prone, safe = subdirs.partition { |d|
    prefix = "#{cat_dir}/#{d}/"
    SKIP.any? { |f| f.start_with?(prefix) }
  }
  # Files directly under cat_dir (rare but exist) go with the safe bucket.
  safe_files = (safe.flat_map { |d| Dir["#{cat_dir}/#{d}/**/*_spec.rb"] } +
                Dir["#{cat_dir}/*_spec.rb"])
              .sort.reject { |f| SKIP.include?(f) }

  fallback_needed = false
  unless safe_files.empty?
    data = run_mspec(TMP, safe_files)
    if data
      aggregate(totals, data)
    else
      warn "::warning::mspec run for #{category} safe sub-dirs produced no yaml; " \
           "falling back to per-file for the whole category"
      fallback_needed = true
    end
  end

  if fallback_needed
    totals = new_totals
    aggregate(totals, run_per_file(cat_dir, TMP))
  else
    hang_prone.sort.each do |d|
      aggregate(totals, run_per_file("#{cat_dir}/#{d}", TMP))
    end
  end
else
  files = Dir["spec/ruby/#{category}/**/*_spec.rb"].sort.reject { |f| SKIP.include?(f) }
  data = run_mspec(TMP, files)
  if data
    aggregate(totals, data)
  else
    warn "::warning::mspec run for #{category} produced no yaml; falling back to per-file"
    aggregate(totals, run_per_file("spec/ruby/#{category}", TMP))
  end
end

File.delete(TMP) if File.exist?(TMP)

result = {
  'exceptions'   => nil,
  'time'         => totals['time'],
  'files'        => totals['files'],
  'examples'     => totals['examples'],
  'expectations' => totals['expectations'],
  'failures'     => totals['failures'],
  'errors'       => totals['errors'],
  'tagged'       => totals['tagged'],
}
File.write(OUT, result.to_yaml)

passing = totals['examples'] - totals['failures'] - totals['errors'] - totals['tagged']
warn "spec/ruby/#{category}: #{passing}/#{totals['examples']} passing " \
     "(#{totals['failures']} failures, #{totals['errors']} errors) in #{totals['time'].round(1)}s"
