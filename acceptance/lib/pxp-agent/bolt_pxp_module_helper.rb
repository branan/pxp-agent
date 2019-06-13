require 'pxp-agent/test_helper.rb'
require 'digest'

def file_entry(filename, sha256, path = 'foo')
  {:uri => {:path => path, :params => {}}, :filename => filename, :sha256 => sha256}
end

# Selects only the agents (not masters) from a set of beaker hosts and produces an array of PCP
# identity strings for them.
#
# @param targets [Array<Beaker::Host>] The hosts
# @return [Array<String>] PCP broker identities of the agent hosts only
def agent_identities(targets)
  # Select the hosts that have the agent role but not the master role (Beaker's
  # `agents` selector selects all of the hosts that have the agent role, but masters
  # typically have _both_ the agent and master roles - this rejection guards against
  # accidentally including the master in this list when working with `agents`).
  agents_only = targets.reject { |host| host['roles'].include?('master') }.to_a
  agents_only.map { |agent| "pcp://#{agent}/agent" }
end

# Make an RPC request to execute a module action and run a callback on the resulting data
#
# @param broker [String|Beaker::Host] Hostname or beaker host object of the PCP broker machine
# @param target_identities [Array<String>] PXP agent identity strings on which to perform the action
# @param module_name [String] The name of the pxp module that contains the action to perform
# @param action_name [String] The name of the action to perform
# @param params [Hash<String,String>] Parameters to pass to the module action when running it
# @param expected_response_type [String] The type of response expected from the action
# @param blocking_request [Boolean] Whether to issue a blocking request (the default is a non-blocking request)
# @yield [Array<Hash<String,String>>] Yields an array of response hashes:
# For a successful response:
#   ["<agent-pcp-identity-string>" => {
#       "transaction_id" => "<uuid>"
#   }]
# When there's been an RPC error, the result is different:
#  ["<agent-pcp-identity-string>" =>  {
#       "data" => {
#           "description" => "<error-message>",
#           "id" => "<uuid>",
#           "transaction_id" => "<uuid>"
#        },
#       "envelope" => {
#           "expires" => "<date-string>",
#           "id" => "<uuid>",
#           "message_type" => "http://puppetlabs.com/<message-type>",
#           "sender" => "<broker-pcp-identity-string>",
#           "targets" => ["<agent-pcp-identity-string", ...]
#        }
#  }]
def do_module_action(broker, target_identities, module_name, action_name, params,
                     blocking_request: false,
                     expected_response_type: 'http://puppetlabs.com/rpc_provisional_response')
  responses =
    begin
      rpc_request = blocking_request ? method(:rpc_blocking_request) : method(:rpc_non_blocking_request)
      rpc_request.call(broker, target_identities, module_name, action_name, params)
    rescue => exception
      fail("Exception occurred when trying to execute '#{module_name}' pxp module's '#{action_name}' action on all agents: #{exception.message}")
    end

  response_dataset = target_identities.map do |identity|
    assert_equal(expected_response_type,
                 responses[identity][:envelope][:message_type],
                 "Did not receive expected rpc_response in reply to RPC request")
    responses[identity][:data]
  end

  yield(response_dataset) if block_given?
end

# Starts a task.
# Block is executed on the "response_dataset" object from do_module_action.
def run_task(broker, targets, task, files, input = {}, metadata = nil, **kwargs, &block)
  params = { task: task, input: input, files: files }
  params[:metadata] = metadata if metadata
  do_module_action(broker, agent_identities(targets), 'task', 'run', params, **kwargs, &block)
end

# Checks that a non-blocking request finished successfully.
# Block is executed on the stdout string.
def ensure_successful(broker, targets, response_dataset, max_retries: 30, query_interval: 1)
  transaction_ids = response_dataset.map { |data| data['transaction_id'] }
  agent_identities(targets).zip(transaction_ids).map do |identity, transaction_id|
    check_non_blocking_response(broker, identity, transaction_id, max_retries, query_interval) do |result|
      assert_equal('success', result['status'], 'Action was expected to succeed')
      assert_equal(nil, result['stderr'], 'Successful action expected to have no output on stderr')
      assert_equal(0, result['exitcode'], 'Successful action expected to have exit code 0')
      yield result['stdout'] if block_given?
    end
  end
end

# Checks that a non-blocking request finished unsuccessfully without erroring.
# Block is executed on the stderr string.
def ensure_failed(broker, targets, response_dataset, max_retries: 30, query_interval: 1)
  transaction_ids = response_dataset.map { |data| data['transaction_id'] }
  agent_identities(targets).zip(transaction_ids).map do |identity, transaction_id|
    check_non_blocking_response(broker, identity, transaction_id, max_retries, query_interval) do |result|
      assert_equal('failure', result['status'], 'Action was expected to fail')
      assert_equal(nil, result['stdout'], 'Successful action expected to have no output on stdout')
      assert_equal(1, result['exitcode'], 'Successful action expected to have exit code 1')
      yield result['stderr'] if block_given?
    end
  end
end

# Runs a non-blocking task action on targets, and confirms that it was successful.
# Block is executed on the stdout string.
def run_successful_task(broker, targets, task, files, input: {}, metadata: nil, **kwargs, &block)
  run_task(broker, targets, task, files, input, metadata, **kwargs) do |datas|
    ensure_successful(broker, targets, datas, **kwargs, &block)
  end
end

# Runs a non-blocking task action on targets, and confirms that it failed but did not error.
# Block is executed on the stderr string.
def run_failed_task(broker, targets, task, files, input: {}, metadata: nil, **kwargs, &block)
  run_task(broker, targets, task, files, input, metadata) do |datas|
    ensure_failed(broker, targets, datas, **kwargs, &block)
  end
end

# Starts a blocking task on targets, and confirms that it produced an RPC error
# Block is executed on the RPC error message string.
def run_errored_task(broker, targets, task, files, input: {}, metadata: nil)
  run_task(broker, targets, task, files, input, metadata,
           blocking_request: true,
           expected_response_type: "http://puppetlabs.com/rpc_error_message") do |response_dataset|
    response_dataset.each { |data| yield data['description'] } if block_given?
  end
end

def get_tasks_cache(agent)
  agent['platform'] =~ /win/ ?
    'C:/ProgramData/PuppetLabs/pxp-agent/tasks-cache'
  : '/opt/puppetlabs/pxp-agent/tasks-cache'
end

def create_task_on(agent, mod, task, body)
  tasks_cache = get_tasks_cache(agent)

  body += "\n" if body[-1] != "\n"
  sha256 = Digest::SHA256.hexdigest(body)
  task_path = "#{tasks_cache}/#{sha256}"
  on agent, "mkdir -p #{task_path}"

  create_remote_file(agent, "#{task_path}/#{task}", body)
  on agent, "chmod +x #{task_path}/#{task}"

  teardown do
    on agent, "rm -rf #{task_path}"
  end

  sha256
end
