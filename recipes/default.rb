#
# Cookbook Name:: jenkins
# Based on hudson
# Recipe:: default
#
# Author:: AJ Christensen <aj@junglist.gen.nz>
# Author:: Doug MacEachern <dougm@vmware.com>
# Author:: Fletcher Nichol <fnichol@nichol.ca>
#
# Copyright 2010, VMware, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

pkey = "#{node[:jenkins][:server][:home]}/.ssh/id_rsa"
tmp = "/tmp"

user node[:jenkins][:server][:user] do
  home node[:jenkins][:server][:home]
end

directory node[:jenkins][:server][:home] do
  recursive true
  owner node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
end

directory "#{node[:jenkins][:server][:home]}/.ssh" do
  mode 0700
  owner node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
end

#cookbook_file "#{pkey}" do
  #source "id_rsa"
  #mode 0600
  #owner node[:jenkins][:server][:user]
  #group node[:jenkins][:server][:group]
#end

#cookbook_file "#{pkey}.pub" do
  #source "id_rsa.pub"
  #mode 0644
  #owner node[:jenkins][:server][:user]
  #group node[:jenkins][:server][:group]
#end

cookbook_file "#{node[:jenkins][:server][:home]}/.ssh/known_hosts" do
  source "github_keys.pub"
  mode 0644
  owner node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
end


execute "ssh-keygen -f #{pkey} -N ''" do
  user  node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
  not_if { File.exists?(pkey) }
end

ruby_block "store jenkins ssh pubkey" do
  block do
    node.set[:jenkins][:server][:pubkey] = File.open("#{pkey}.pub") { |f| f.gets }
  end
end

template "#{node[:jenkins][:server][:home]}/.gitconfig" do
  source "dot_gitconfig.erb"
  mode 0664
  owner node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
end

directory "#{node[:jenkins][:server][:home]}/plugins" do
  owner node[:jenkins][:server][:user]
  group node[:jenkins][:server][:group]
  only_if { node[:jenkins][:server][:plugins].size > 0 }
end

node[:jenkins][:server][:plugins].each do |name|
  remote_file "#{node[:jenkins][:server][:home]}/plugins/#{name}.hpi" do
    source "#{node[:jenkins][:mirror]}/plugins/#{name}/latest/#{name}.hpi"
    backup false
    owner node[:jenkins][:server][:user]
    group node[:jenkins][:server][:group]
    action :create_if_missing
  end
end

case node.platform
when "ubuntu", "debian"
  include_recipe "apt"
  include_recipe "java"

  pid_file = "/var/run/jenkins/jenkins.pid"
  install_starts_service = false

  apt_repository "jenkins" do
    uri "#{node.jenkins.package_url}/debian"
    components %w[binary/]
    key "http://pkg.jenkins-ci.org/debian/jenkins-ci.org.key"
    #action :add
  end
  cookbook_file "/etc/apt/sources.list.d/jenkins.list" do
    mode        '0644'
    source "jenkins.list"
    notifies :run, resources(:execute => "apt-get update"), :immediately
  end

when "centos", "redhat"
  include_recipe "yum"

  pid_file = "/var/run/jenkins.pid"
  install_starts_service = false

  yum_key "jenkins" do
    url "#{node.jenkins.package_url}/redhat/jenkins-ci.org.key"
    action :add
  end

  yum_repository "jenkins" do
    description "repository for jenkins"
    url "#{node.jenkins.package_url}/redhat/"
    key "jenkins"
    action :add
  end
end

#"jenkins stop" may (likely) exit before the process is actually dead
#so we sleep until nothing is listening on jenkins.server.port (according to netstat)
ruby_block "netstat" do
  block do
    10.times do
      if IO.popen("netstat -lnt").entries.select { |entry|
          entry.split[3] =~ /:#{node[:jenkins][:server][:port]}$/
        }.size == 0
        break
      end
      Chef::Log.debug("service[jenkins] still listening (port #{node[:jenkins][:server][:port]})")
      sleep 1
    end
  end
  action :nothing
end


service "jenkins" do
  supports [ :stop, :start, :restart, :status ]
  status_command "test -f #{pid_file} && kill -0 `cat #{pid_file}`"
  action :nothing
end

ruby_block "block_until_operational" do
  block do
    until IO.popen("netstat -lnt").entries.select { |entry|
        entry.split[3] =~ /:#{node[:jenkins][:server][:port]}$/
      }.size == 1
      Chef::Log.debug "service[jenkins] not listening on port #{node.jenkins.server.port}"
      sleep 1
    end

    loop do
      url = URI.parse("#{node.jenkins.server.url}/job/test/config.xml")
      res = Chef::REST::RESTRequest.new(:GET, url, nil).call
      break if res.kind_of?(Net::HTTPSuccess) or res.kind_of?(Net::HTTPNotFound)
      Chef::Log.debug "service[jenkins] not responding OK to GET / #{res.inspect}"
      sleep 1
    end
  end
  action :nothing
end

log "jenkins: install and start" do
  notifies :install, "package[jenkins]", :immediately
  notifies :start, "service[jenkins]", :immediately unless install_starts_service
  notifies :create, "ruby_block[block_until_operational]", :immediately
  not_if do
    File.exists? "/usr/share/jenkins/jenkins.war"
  end
end

bound_interface = node[:jenkins][:server][:url]
case node[:jenkins][:http_proxy][:variant]
when "nginx","apache2"
    bound_interface = "localhost"
end
node[:jenkins][:server][:url]  = "http://#{bound_interface}:#{node[:jenkins][:server][:port]}"

template "/etc/default/jenkins" do
  source "jenkins.erb"
  owner       'root'
  group       'root'
  mode        '0644'
  variables :bound_interface => bound_interface
  notifies  :restart, 'service[jenkins]'
end

template "/etc/init/jenkins.conf" do
  source      "jenkins.conf.erb"
  owner       'root'
  group       'root'
  mode        '0644'
  variables(
    :port => node[:jenkins][:server][:port],
    :java_home => node[:java][:java_home]
  )

  if File.exists?("#{node[:nginx][:dir]}/sites-enabled/jenkins.conf")
    notifies  :restart, 'service[jenkins]'
  end
end

template "#{node[:jenkins][:server][:home]}/hudson.tasks.Maven.xml" do
  owner       'jenkins'
  group       'jenkins'
  mode        '0644'
  variables(
    :m2label => "maven#{node[:maven][:version]}",
    :m2home => node[:maven][:m2_home]
  )
end

package "jenkins" do
  action :nothing
  notifies :create, "template[/etc/default/jenkins]", :immediately
  notifies :create, "template[/etc/init/jenkins.conf]", :immediately
  notifies :create, "template[#{node[:jenkins][:server][:home]}/hudson.tasks.Maven.xml]", :immediately
end

# restart if this run only added new plugins
log "plugins updated, restarting jenkins" do
  #ugh :restart does not work, need to sleep after stop.
  notifies :stop, "service[jenkins]", :immediately
  notifies :create, "ruby_block[netstat]", :immediately
  notifies :start, "service[jenkins]", :immediately
  notifies :create, "ruby_block[block_until_operational]", :immediately
  only_if do
    if File.exists?(pid_file)
      htime = File.mtime(pid_file)
      Dir["#{node[:jenkins][:server][:home]}/plugins/*.hpi"].select { |file|
        File.mtime(file) > htime
      }.size > 0
    end
  end

  action :nothing
end

# Front Jenkins with an HTTP server
case node[:jenkins][:http_proxy][:variant]
when "nginx"
  include_recipe "jenkins::proxy_nginx"
when "apache2"
  include_recipe "jenkins::proxy_apache2"
end

if node.jenkins.iptables_allow == "enable"
  include_recipe "iptables"
  iptables_rule "port_jenkins" do
    if node[:jenkins][:iptables_allow] == "enable"
      enable true
    else
      enable false
    end
  end
end


builds = data_bag('builds')
builds.each do | b |
    build = data_bag_item('builds', b)
    branch = build['branch']
    component = build['component']
    repository = build['repository']
    build_on_change = build['build_on_change']

    job_name = "#{component}-#{branch}"

    job_config = File.join(node[:jenkins][:server][:home], "#{job_name}-config.xml")

    jenkins_job job_name do
      action :nothing
      config job_config
    end


    template job_config do
      owner       'jenkins'
      group       'jenkins'
      mode        '0644'
      source "#{component}-#{branch}-config.xml.erb"
      variables(
        :job_name => job_name, :branch => branch, :node => node[:fqdn], :repository => repository,
        :groupId => build['groupId'],
        :artifactId => build['artifactId'],
        :roles => build['roles'],
        :goal => build['goal'],
        :ami => build['ami'],
        :server_size => build['server_size'],
        :ec2_ssh_key => build['ec2_ssh_key'],
        :ec2_security_group => build['ec2_security_group'],
        :chef_bootstrap => build['chef_bootstrap'],
        :ami_user => build['ami_user'],
        :ec2_ssh_key_file => build['ec2_ssh_key_file'],
        :ec2_region => build['ec2_region'] )
      notifies :update, resources(:jenkins_job => job_name), :immediately
      notifies :build, resources(:jenkins_job => job_name), :delayed if build_on_change
    end

end

