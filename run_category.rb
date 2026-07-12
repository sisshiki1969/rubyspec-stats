# Runs a spec dir (core or library) against monoruby. Sub-dirs with a file
# in SPEC_SKIP_FILE run per-file via run_specs.rb (some specs hang monoruby);
# the rest run in one mspec-run process. Writes stats.yml.
#
# Usage: ruby run_category.rb <spec_dir>
# Env:   SPEC_SKIP_FILE, SPEC_TIMEOUT, SPEC_JOBS

require 'yaml'
require 'set'

spec_dir = ARGV[0] or abort 'usage: ruby run_category.rb <spec_dir>'

MSPEC_RUN = 'spec/mspec/bin/mspec-run'
TARGET    = 'monoruby'
OUT       = 'stats.yml'
TMP       = "#{OUT}.tmp"
RUN_SPECS = File.join(__dir__, 'run_specs.rb')

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
  system('timeout', '300', TARGET, MSPEC_RUN,
         '--format', 'yaml', '--output', out, *files, in: File::NULL)
  load_yaml(out)
end

def run_per_file(spec_dir, out)
  system('ruby', RUN_SPECS, MSPEC_RUN, TARGET, spec_dir, out)
  load_yaml(out)
end

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

subdirs = Dir.children(spec_dir).select { |d| File.directory?(File.join(spec_dir, d)) }
hang_prone, safe = subdirs.partition { |d|
  prefix = "#{spec_dir}/#{d}/"
  SKIP.any? { |f| f.start_with?(prefix) }
}
safe_files = (safe.flat_map { |d| Dir["#{spec_dir}/#{d}/**/*_spec.rb"] } +
              Dir["#{spec_dir}/*_spec.rb"])
            .sort.reject { |f| SKIP.include?(f) }

fallback_needed = false
unless safe_files.empty?
  data = run_mspec(TMP, safe_files)
  if data
    aggregate(totals, data)
  else
    warn "::warning::mspec run for #{spec_dir} safe sub-dirs produced no yaml; " \
         "falling back to per-file for the whole category"
    fallback_needed = true
  end
end

if fallback_needed
  totals = new_totals
  aggregate(totals, run_per_file(spec_dir, TMP))
else
  hang_prone.sort.each do |d|
    aggregate(totals, run_per_file("#{spec_dir}/#{d}", TMP))
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
warn "#{spec_dir}: #{passing}/#{totals['examples']} passing " \
     "(#{totals['failures']} failures, #{totals['errors']} errors) in #{totals['time'].round(1)}s"
