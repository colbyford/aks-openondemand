require 'erb'
require 'yaml'
require 'fileutils'
require 'ostruct'
require 'pathname'
require 'tmpdir'

CHART = File.expand_path('..', __dir__)
WORK = Dir.mktmpdir('ondemand-apps-', '/tmp')
ORIGINAL_FILE_OPEN = File.method(:open)
ORIGINAL_FILE_REALPATH = File.method(:realpath)

# All virtual home writes stay under this test's temporary directory.
module TestFiles
  def map_path(path)
    path.to_s.sub(%r{\A/home/ondemand(?=/|$)}, "#{WORK}/home")
        .sub(%r{\A/var/www/ood/apps/sys/}, "#{CHART}/files/apps/")
  end

  def read(path, *args)
    super(map_path(path), *args)
  end

  def open(path, *args, &block)
    ORIGINAL_FILE_OPEN.call(map_path(path), *args, &block)
  end

  def realpath(path, *args)
    super(map_path(path), *args)
      .sub(ORIGINAL_FILE_REALPATH.call("#{WORK}/home"), '/home/ondemand')
  end

  def file?(path)
    super(map_path(path))
  end
end
File.singleton_class.prepend(TestFiles)
module TestPaths
  def file?
    File.file?(to_s)
  end
end
Pathname.prepend(TestPaths)
module TestDirectories
  def mkdir_p(path, **options)
    super(File.map_path(path), **options)
  end
end
FileUtils.singleton_class.prepend(TestDirectories)

def check(value, message)
  raise message unless value
end

def submit(app, **attributes)
  defaults = {cpu: '1', memory: '2', hours: '1',
              staged_root: '/home/ondemand/sessions/test', interface: 'lab',
              script_path: 'scripts/example.sh'}
  context = OpenStruct.new(defaults.merge(attributes))
  source = File.read("#{CHART}/files/apps/#{app}/submit.yml.erb")
  YAML.safe_load(ERB.new(source).result(context.instance_eval { binding }))
end

def rejects(app, **attributes)
  begin
    submit(app, **attributes)
  rescue ArgumentError, RuntimeError
    return
  end
  raise "Accepted invalid #{attributes.inspect}"
end

begin
  FileUtils.mkdir_p("#{WORK}/home/scripts")
  File.write("#{WORK}/home/scripts/example.sh", "echo hello\n")
  ENV['OOD_JUPYTER_IMAGE'] = ENV['OOD_BATCH_IMAGE'] = 'quay.io/jupyter/base-notebook:2025-03-14'
  ENV['OOD_DESKTOP_IMAGE'] = 'docker.io/example/xfce-novnc:2025-03-14'
  ENV['OOD_NODE_HOST_REGEX'] = '10\.0\.1\.[0-9]{1,3}'
  %w[jupyter batch desktop].each do |app|
    YAML.safe_load(ERB.new(File.read("#{CHART}/files/apps/#{app}/form.yml.erb")).result)
    YAML.safe_load(File.read("#{CHART}/files/apps/#{app}/manifest.yml"))
    options = submit(app, cpu: '99', memory: '-1', hours: '99')
    container = options.fetch('script').fetch('native').fetch('container')
    check(container['cpu'] == '4' && container['memory'] == '1Gi', 'Resource clamp failed')
    check(options['script']['wall_time'] == 86400, 'Runtime clamp failed')
    check(container['command'] == ['bash', '/ood/runner.sh'], 'Unsafe command')
    check(container['restart_policy'] == 'Never', 'Job must not restart')
    file = options['script']['native']['configmap']['files'].first
    check(file['data'] == File.read("#{CHART}/files/apps/#{app}/runner.sh"), 'Runner changed')
    # The verified upstream template quotes every command/env value without escaping.
    quoted = ERB.new("command:\n<% container['command'].each do |v| %>  - \"<%= v %>\"\n<% end %>env:\n<% container['env'].each do |k,v| %>  - name: <%= k %>\n    value: \"<%= v %>\"\n<% end %>").result(binding)
    YAML.safe_load(quoted)
    %w[1.5 garbage].each { |value| rejects(app, cpu: value) }
    rejects(app, staged_root: '/home/ondemand/sessions/../evil')
    rejects(app, staged_root: "/home/ondemand/session\"\nimage: evil")
  end
  rejects('jupyter', interface: 'evil')
  %w[../escape.sh /absolute.sh scripts/a\ b.sh a.sh\;evil scripts/../../bad.sh].each do |path|
    rejects('batch', script_path: path)
  end
  File.symlink('/etc/passwd', "#{WORK}/home/scripts/escape.sh")
  rejects('batch', script_path: 'scripts/escape.sh')
  lab = submit('jupyter')
  check(lab['script']['native']['container']['env']['OOD_TOKEN'].match?(/\A[0-9a-f]{64}\z/), 'Weak token')
  check((File.stat("#{WORK}/home/sessions/test/token").mode & 0777) == 0600, 'Token permissions')
  check((File.stat("#{WORK}/home/sessions/test").mode & 0777) == 0700, 'Session permissions')
  submit('jupyter', interface: 'notebook')
  connect = OpenStruct.new(host: 'reverse.example', port: 30001,
                           host_ip: '10.0.1.5', node_port: 30001,
                           token: 'a' * 64, interface_path: 'tree')
  view = ERB.new(File.read("#{CHART}/files/apps/jupyter/view.html.erb"))
            .result(connect.instance_eval { binding })
  check(view.include?('/node/10.0.1.5/30001/tree?token='), 'View base URL mismatch')
  connect = OpenStruct.new(host: 'reverse.example', port: 30001)
  view = ERB.new(File.read("#{CHART}/files/apps/jupyter/view.html.erb"))
            .result(connect.instance_eval { binding })
  check(view.include?('initializing'), 'View readiness race')
  desktop = submit('desktop')
  check(desktop['script']['native']['container']['env']['OOD_PASSWORD'].match?(/\A[A-Za-z0-9]{8}\z/), 'Weak VNC password')
  check(desktop['script']['native']['container']['port'] == 8888, 'Desktop must target the allowed workload port')
  check((File.stat("#{WORK}/home/sessions/test/password").mode & 0777) == 0600, 'Password permissions')
  connect = OpenStruct.new(host_ip: '10.0.1.5', node_port: 30001, password: 'Abcd1234')
  view = ERB.new(File.read("#{CHART}/files/apps/desktop/view.html.erb"))
            .result(connect.instance_eval { binding })
  check(view.include?('/node/10.0.1.5/30001/vnc_lite.html'), 'Desktop view URL mismatch')
  check(view.include?('path=node%2F10.0.1.5%2F30001%2Fwebsockify'), 'Desktop websocket path mismatch')
  connect = OpenStruct.new(host_ip: '10.0.1.5', node_port: 30001, password: 'bad"word')
  begin
    ERB.new(File.read("#{CHART}/files/apps/desktop/view.html.erb"))
       .result(connect.instance_eval { binding })
    raise 'Accepted invalid VNC password'
  rescue RuntimeError => error
    raise error if error.message == 'Accepted invalid VNC password'
  end
  connect = OpenStruct.new(host_ip: '10.0.1.5')
  view = ERB.new(File.read("#{CHART}/files/apps/desktop/view.html.erb"))
            .result(connect.instance_eval { binding })
  check(view.include?('initializing'), 'Desktop view readiness race')
  puts 'PASS: forms, native YAML, clamps, invalid inputs, symlink escape, tokens, Notebook and Desktop views'
ensure
  FileUtils.rm_rf(WORK)
end
