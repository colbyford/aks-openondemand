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
         batchImage: 'quay.io/jupyter/base-notebook:2025-03-14',
         desktopImage: 'docker.io/example/xfce-novnc:2025-03-14'},
  slurm: {enabled: true, image: 'example/slurm:1.0',
          existingMungeSecret: 'ondemand-munge'},
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
raise 'Desktop app missing when desktopImage is set' unless
  find.call('ConfigMap').any? { |c| c['metadata']['name'] == 'portal-ondemand-desktop' } &&
  deployment['spec']['template']['spec']['containers'][0]['env'].any? { |e| e['name'] == 'OOD_DESKTOP_IMAGE' }
no_desktop = Marshal.load(Marshal.dump(values))
no_desktop[:apps][:desktopImage] = ''
no_desktop_output, no_desktop_errors, no_desktop_status = run_helm('template', chart, no_desktop)
raise no_desktop_errors unless no_desktop_status.success?
raise 'Desktop app must stay disabled without desktopImage' if
  no_desktop_output.include?('portal-ondemand-desktop') || no_desktop_output.include?('OOD_DESKTOP_IMAGE')
slurm_set = find.call('StatefulSet').find { |s| s['metadata']['name'] == 'portal-ondemand-slurm' }
raise 'Slurm login cluster missing when enabled' unless slurm_set &&
  find.call('ConfigMap').any? { |c| c.dig('data', 'slurm.conf')&.include?('NodeName=portal-ondemand-slurm-0') } &&
  portal_config['data']['slurm-cluster.yml'].include?('host: portal-ondemand-slurm-0.portal-ondemand-slurm')
portal_env = deployment['spec']['template']['spec']['containers'][0]['env']
raise 'Shell must be enabled with Slurm' unless
  portal_env.any? { |e| e['name'] == 'OOD_SHELL_ENABLED' && e['value'] == 'true' } &&
  !portal_config['data']['dashboard-env'].include?('OOD_DISABLE_SHELL')
no_slurm = Marshal.load(Marshal.dump(values))
no_slurm[:slurm] = {enabled: false}
no_slurm_output, no_slurm_errors, no_slurm_status = run_helm('template', chart, no_slurm)
raise no_slurm_errors unless no_slurm_status.success?
no_slurm_resources = YAML.load_stream(no_slurm_output).compact
raise 'Slurm resources must stay disabled' if no_slurm_resources.any? { |r| r['kind'] == 'StatefulSet' }
no_slurm_config = no_slurm_resources.find { |r| r['kind'] == 'ConfigMap' && r['data']['dashboard-env'] }
raise 'Shell must stay disabled without Slurm' unless
  no_slurm_config['data']['dashboard-env'].include?('OOD_DISABLE_SHELL=true') &&
  no_slurm_config['data']['slurm-cluster.yml'].nil?

required = [
  [:image, :repository], [:image, :tag], [:auth, :existingSecret],
  [:ingress, :host], [:ingress, :tlsSecret], [:nfs, :server], [:nfs, :path],
  [:apps, :jupyterImage], [:apps, :batchImage],
  [:slurm, :image], [:slurm, :existingMungeSecret],
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
