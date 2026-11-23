require 'json'
require 'yaml'
require 'open3'

chart = File.expand_path('..', __dir__)
values = {
  image: {repository: 'example/portal', tag: '4.0'},
  auth: {existingSecret: 'portal-auth'},
  ingress: {host: 'ood.example.org', tlsSecret: 'portal-tls'},
  nfs: {server: '10.0.2.4', path: '/export'},
  apps: {jupyterImage: 'quay.io/jupyter/base-notebook:2025-03-14',
         batchImage: 'quay.io/jupyter/base-notebook:2025-03-14'},
  networkPolicy: {nodeSubnetCIDR: '10.0.1.0/24',
                  nodeHostRegex: '10\.0\.1\.[0-9]{1,3}',
                  apiServerCIDRs: ['10.0.0.4/32']}
}

def run_helm(command, chart, values)
  Open3.capture3('helm', command, 'portal', chart, '--namespace', 'portal',
                '-f', '-', stdin_data: JSON.generate(values))
end

output, errors, status = run_helm('template', chart, values)
raise errors unless status.success?
lint_output, lint_errors, lint_status = Open3.capture3('helm', 'lint', chart, '-f', '-',
                                                      stdin_data: JSON.generate(values))
raise lint_output + lint_errors unless lint_status.success?
resources = YAML.load_stream(output).compact
find = ->(kind) { resources.select { |resource| resource['kind'] == kind } }
deployment = find.call('Deployment').first
raise 'Replication unsafe' unless deployment['spec']['replicas'] == 1 &&
                                 deployment['spec']['strategy']['type'] == 'Recreate'
raise 'Portal must be internal' unless find.call('Service').all? { |s| s['spec']['type'] == 'ClusterIP' }
raise 'Chart owns pre-existing portal namespace' unless find.call('Namespace').map { |n| n['metadata']['name'] } == ['portal-ondemand-jobs-ondemand']
raise 'Baseline NFS admission missing' unless find.call('ValidatingAdmissionPolicy').size == 1
roles = find.call('Role')
raise 'Unexpected role permissions' unless roles.all? { |r| r['metadata']['namespace'] == 'portal-ondemand-jobs-ondemand' }
discovery = roles.find { |r| r['metadata']['name'] == 'connection-discovery' }
raise 'Workload token permissions unexpected' unless discovery['rules'] == [
  {'apiGroups' => [''], 'resources' => ['pods', 'services'], 'verbs' => ['get']},
  {'apiGroups' => [''], 'resources' => ['secrets'], 'verbs' => ['create']}
]
pod_spec = deployment['spec']['template']['spec']
api_token_volume = pod_spec['volumes'].find { |volume| volume['name'] == 'api-token' }
raise 'Projected token must be readable by the PUN user' unless
  pod_spec['securityContext']['runAsUser'].nil? &&
  pod_spec['securityContext']['runAsGroup'].nil? &&
  api_token_volume.dig('projected', 'defaultMode') == 292
find.call('ConfigMap').each do |config|
  next unless config['data']['submit']
  raise 'Helm consumed ERB' unless config['data']['submit'].include?('<%= YAML.dump(options) %>')
end
portal_config = find.call('ConfigMap').find { |c| c['data']['ood_portal.yml'] }
ood = YAML.safe_load(portal_config['data']['ood_portal.yml'])
raise 'Upstream TLS rewrite loop' unless ood['ssl'].nil? && ood['use_rewrites'] == false
raise 'Unexpected user map command' unless ood['user_map_match'] == '^ondemand$' &&
                                           ood['user_map_cmd'].nil?
raise 'Anchored nested URL regex' if ood['host_regex'].match?(/[\^$]/)
raise 'Missing kubeconfig seed' unless deployment['spec']['template']['spec']['containers'][0]['volumeMounts'].any? { |m| m['mountPath'] == '/etc/ood/kubeconfig.template' }

required = [
  [:image, :repository], [:image, :tag], [:auth, :existingSecret],
  [:ingress, :host], [:ingress, :tlsSecret], [:nfs, :server], [:nfs, :path],
  [:apps, :jupyterImage], [:apps, :batchImage],
  [:networkPolicy, :nodeSubnetCIDR], [:networkPolicy, :nodeHostRegex],
  [:networkPolicy, :apiServerCIDRs]
]
required.each do |group, key|
  bad = Marshal.load(Marshal.dump(values))
  bad[group][key] = key == :apiServerCIDRs ? [] : ''
  _, _, result = run_helm('template', chart, bad)
  raise "Missing #{group}.#{key} accepted" if result.success?
end
puts "PASS: Helm lint, #{resources.size} YAML resources, RBAC/namespace/TLS invariants and #{required.size} required-value failures"
