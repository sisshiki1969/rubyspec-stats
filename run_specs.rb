# Runs a spec dir per-file against a target Ruby (parallel workers under a
# timeout) so a single hanging / crashing file doesn't lose the whole category.
#
# Usage: ruby run_specs.rb <mspec-run> <target> <spec_dir> <out.yml>
# Env:   SPEC_TIMEOUT, SPEC_JOBS, SPEC_SKIP_FILE

require 'yaml'
require 'tmpdir'
require 'etc'
require 'set'

mspec_run, target, spec_dir, out = ARGV
abort "usage: ruby run_specs.rb <mspec-run> <target> <spec_dir> <out.yml>" unless out

timeout = ENV.fetch('SPEC_TIMEOUT', '30')
jobs    = Integer(ENV.fetch('SPEC_JOBS', Etc.nprocessors.to_s))
skip_file = ENV['SPEC_SKIP_FILE']
skip = skip_file && File.exist?(skip_file) ?
  File.readlines(skip_file, chomp: true).reject(&:empty?).to_set : Set.new

files = Dir.glob(File.join(spec_dir, '**', '*_spec.rb')).sort.reject { |f| skip.include?(f) }

# Warm the target's caches once before running in parallel.
system(target, '-e', '', in: File::NULL, out: File::NULL, err: File::NULL)

SUMMED = %w[files examples expectations failures errors tagged]
sum = Hash.new(0)
total_time = 0.0
mutex = Mutex.new
queue = files.each_index.to_a
qmutex = Mutex.new

run_file = lambda do |file, tmp|
  File.delete(tmp) if File.exist?(tmp)
  system('timeout', timeout, target, mspec_run,
         '--format', 'yaml', '--output', tmp, file,
         in: File::NULL, out: File::NULL, err: File::NULL)
  data = (YAML.load_file(tmp) if File.exist?(tmp) && File.size?(tmp)) rescue nil
  mutex.synchronize do
    if data
      # Clamp examples >= failures+errors+tagged so passing stays non-negative.
      counted = data['failures'].to_i + data['errors'].to_i + data['tagged'].to_i
      data['examples'] = [data['examples'].to_i, counted].max
      SUMMED.each { |k| sum[k] += data[k].to_i }
      total_time += data['time'].to_f
    else
      # Target killed the file: count it as one failing example.
      sum['files']    += 1
      sum['examples'] += 1
      sum['errors']   += 1
      warn "#{target} could not run #{file}"
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
