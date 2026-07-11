# Runs ruby/spec for one category against a target Ruby and writes an
# mspec-style YAML summary (same shape as `mspec --format yaml`, minus the
# per-failure `exceptions` list, to keep the committed file small).
#
# Implementations such as monoruby may segfault or spin forever on individual
# specs, which would abort or hang a single whole-category mspec process and
# lose every result. Each spec file is therefore run in its own mspec process
# under an external timeout, in parallel, so a bad file only costs that one file
# while the rest of the category is still measured.
#
# Usage: ruby run_specs.rb <mspec> <target> <spec_dir> <out.yml>
# Env:   SPEC_TIMEOUT    seconds before a single spec file is killed (default 30)
#        SPEC_JOBS       parallel mspec processes (default: number of CPUs)
#        SPEC_SKIP_FILE  optional file listing spec paths to skip (one per line);
#                        useful for spec files known to hang the target, so the
#                        runner doesn't spend `SPEC_TIMEOUT` on each of them

require 'yaml'
require 'tmpdir'
require 'etc'
require 'set'

mspec, target, spec_dir, out = ARGV
abort "usage: ruby run_specs.rb <mspec> <target> <spec_dir> <out.yml>" unless out

timeout = ENV.fetch('SPEC_TIMEOUT', '30')
jobs    = Integer(ENV.fetch('SPEC_JOBS', Etc.nprocessors.to_s))
skip_file = ENV['SPEC_SKIP_FILE']
skip = skip_file && File.exist?(skip_file) ?
  File.readlines(skip_file, chomp: true).reject(&:empty?).to_set : Set.new

files = Dir.glob(File.join(spec_dir, '**', '*_spec.rb')).sort.reject { |f| skip.include?(f) }

# Warm monoruby's load-path probe / cache once before running in parallel.
system(target, '-e', '', in: File::NULL, out: File::NULL, err: File::NULL)

SUMMED = %w[files examples expectations failures errors tagged]
sum = Hash.new(0)
total_time = 0.0
mutex = Mutex.new
queue = files.each_index.to_a
qmutex = Mutex.new

run_file = lambda do |file, tmp|
  File.delete(tmp) if File.exist?(tmp)
  system('timeout', timeout, mspec, 'run', '-t', target,
         '--format', 'yaml', '--output', tmp, file,
         in: File::NULL, out: File::NULL, err: File::NULL)
  data = (YAML.load_file(tmp) if File.exist?(tmp) && File.size?(tmp)) rescue nil
  mutex.synchronize do
    if data
      # mspec's `errors` counter increments for every exception, including ones
      # that happen outside an example (spec file load failures, `before(:all)`
      # hook failures). Each such event adds 1 to errors but 0 to examples, so
      # errors + failures can exceed examples and drive `passing = examples -
      # errors - failures - tagged` negative for implementations with many
      # load-time failures (e.g. monoruby, whose stdlib coverage is partial).
      # Treat each such extra error as one attempted example so the file's
      # contribution to the aggregate stays consistent.
      counted = data['failures'].to_i + data['errors'].to_i + data['tagged'].to_i
      data['examples'] = [data['examples'].to_i, counted].max
      SUMMED.each { |k| sum[k] += data[k].to_i }
      total_time += data['time'].to_f
    else
      # The file killed the target (segfault or timeout). Count it as one
      # failing example so it is reflected in the pass rate, not dropped.
      sum['files']    += 1
      sum['examples'] += 1
      sum['errors']   += 1
      warn "monoruby could not run #{file}"
    end
  end
end

Dir.mktmpdir do |dir|
  workers = Array.new(jobs) do |w|
    Thread.new do
      tmp = File.join(dir, "batch_#{w}.yml")
      loop do
        i = qmutex.synchronize { queue.shift }
        break unless i
        run_file.call(files[i], tmp)
      end
    end
  end
  workers.each(&:join)
end

result = {
  'exceptions'   => nil,
  'time'         => total_time,
  'files'        => sum['files'],
  'examples'     => sum['examples'],
  'expectations' => sum['expectations'],
  'failures'     => sum['failures'],
  'errors'       => sum['errors'],
  'tagged'       => sum['tagged'],
}
File.write(out, result.to_yaml)

passing = sum['examples'] - sum['failures'] - sum['errors'] - sum['tagged']
warn "#{spec_dir}: #{passing}/#{sum['examples']} passing " \
     "(#{sum['failures']} failures, #{sum['errors']} errors) in #{total_time.round(1)}s"
