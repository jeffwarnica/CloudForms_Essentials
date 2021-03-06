# =begin
#  add_vm_to_service.rb
#
#  Author: Kevin Morey <kevin@redhat.com>
#
#  Description: This method performs the following
#     a) add the provisioned vm to a service after Post Provisioning
#     b) sets vm group ownership
#     c) tags the vm with all rbac_array tags since we do do this by default
#     d) tags vms or services with flex attributes
# ------------------------------------------------------------------------------
#
#     Copyright 2016 Kevin Morey <kevin@redhat.com>
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.
# ------------------------------------------------------------------------------
# =end

def log(level, msg, update_message = false)
  $evm.log(level, msg.to_s)
  @task.message = msg if @task && (update_message || level == 'error')
end

# basic retry logic
def retry_method(retry_time, msg = 'INFO')
  log(:info, "#{msg} - Waiting #{retry_time} seconds}", true)
  $evm.root['ae_result'] = 'retry'
  $evm.root['ae_retry_interval'] = retry_time
  exit MIQ_OK
end

def process_tags(category, single_value, tag)
  # Convert to lower case and replace all non-word characters with underscores
  category_name = category.to_s.downcase.gsub(/\W/,'_')
  tag_name = tag.to_s.downcase.gsub(/\W/,'_')

  # if the category exists else create it
  unless $evm.execute('category_exists?', category_name)
    log(:info, "Category <#{category_name}> doesn't exist, creating category")
    $evm.execute('category_create', :name => category_name, :single_value => single_value, :description => "#{category}")
  end
  # if the tag exists else create it
  unless $evm.execute('tag_exists?', category_name, tag_name)
    log(:info, "Adding new tag <#{tag_name}> in Category <#{category_name}>")
    $evm.execute('tag_create', category_name, :name => tag_name, :description => "#{tag}")
  end
end


def add_vm_to_service(vm, ws_values)
  log(:info, "Processing add_vm_to_service...", true)
  return if @service.nil?
  log(:info, "Adding VM: #{vm.name} to Service: #{@service.name}", true)
  vm.add_to_service(@service)
  log(:info, "Service: #{@service.name} vms: #{@service.vms.count} tags: #{@service.tags}")
  log(:info, "Processing add_vm_to_service...Complete", true)
end

def set_group_ownership(vm, ws_values)
  log(:info, "Processing set_group_ownership...", true)
  # get :group_id from @task.options or ws_values (This is set during the Build_VMProvisionRequest)
  group_id = ws_values[:group_id] || @task.get_option(:group_id)
  return if group_id.nil?
  log(:info, "Found group_id: #{group_id.inspect}") unless group_id.nil?
  @group = $evm.vmdb(:miq_group).find_by_id(group_id)

  return if @group.nil?
  log(:info, "Assigning ownership for group: #{@group.description} to VM: #{vm.name}", true)
  vm.group = @group
  log(:info, "Processing set_group_ownership...Complete", true)
end

def get_current_group_rbac_array
  rbac_array = []
  group = @group || @task.miq_request.requester.current_group
  unless group.filters.blank?
    group.filters['managed'].flatten.each do |filter|
      next unless /(?<category>\w*)\/(?<tag>\w*)$/i =~ filter
      rbac_array << {category=>tag}
    end
  end
  log(:info, "group: #{group.description} RBAC filters: #{rbac_array}")
  return rbac_array
end

def tag_object_with_rbac(obj)
  get_current_group_rbac_array.each do |rbac_hash|
    rbac_hash.each do |rbac_category, rbac_tags|
      Array.wrap(rbac_tags).each do |rbac_tag_entry|
        log(:info, "Assigning Tag: {#{rbac_category}=>#{rbac_tag_entry}} to object: #{obj.name}")
        unless obj.tagged_with?(rbac_category, rbac_tag_entry)
          obj.tag_assign("#{rbac_category}/#{rbac_tag_entry}")
        end
      end
    end
  end
end

begin
  $evm.root.attributes.sort.each { |k, v| log(:info, "\t Attribute: #{k} = #{v}")}

  # Get miq_provision from root
  @task = $evm.root['service_template_provision_task']
  @service = @task.destination

  log(:info, "Provision:<#{@task.id}> Service:<#{@service.name}>")

  vm = @task.vm
  retry_method(15.seconds, "Waiting for VM: #{@task.get_option(:vm_target_name)}") if vm.nil?

  ws_values = @task.options.fetch(:ws_values, {})
  log(:info, "WS Values: #{ws_values.inspect}")

  prov_tags = @task.get_tags
  log(:info, "Inspecting miq_provision tags: #{prov_tags}")

  @service = vm.service || get_service(ws_values)

  add_vm_to_service(vm, ws_values) #unless @service

  # set_group_ownership(vm, ws_values)

  tag_object_with_rbac(vm)
  tag_object_with_rbac(@service) if @service

  # Set Ruby rescue behavior
rescue => err
  log(:error, "[(#{err.class})#{err}]\n#{err.backtrace.join("\n")}")
  exit MIQ_STOP
end
