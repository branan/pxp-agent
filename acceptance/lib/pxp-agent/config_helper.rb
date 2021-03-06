require 'json'
# This file contains common strings and functions for working with pxp-agent's config file

PXP_CONFIG_DIR_CYGPATH = '/cygdrive/c/ProgramData/PuppetLabs/pxp-agent/etc/'
PXP_CONFIG_DIR_POSIX = '/etc/puppetlabs/pxp-agent/'

PCP_BROKER_PORT = 8142

def windows?(host)
  host.platform.upcase.start_with?('WINDOWS')
end

# @param host the beaker host object you want the path on
# @return the path to the directory that pxp-agent is located in. A cygpath is returned in the case of Windows.
def pxp_agent_dir(host)
  if (windows?(host))
    # If 32bit Puppet on 64bit Windows then Puppet will be in Program Files (x86)
    if((host.is_x86_64?) && (host[:ruby_arch] == "x86"))
      return "/cygdrive/c/Program\\ Files\\ \\(x86\\)/Puppet\\ Labs/Puppet/pxp-agent/bin"
    end
    return "/cygdrive/c/Program\\ Files/Puppet\\ Labs/Puppet/pxp-agent/bin"
  end
  "/opt/puppetlabs/puppet/bin"
end

# @param broker hostname or beaker host object of the machine running pcp-broker
# @param agent beaker host object of the agent machine that will receive this config
# @param ssl_config hash of strings for the config keys
#                   :broker_ws_uri - the pcp-broker uri (optional, will default using the broker hostname if not set)
#                   :ssl_key - the private key file (mandatory)
#                   :ssl_ca_cert - the ca file for the ssl keys (mandatory)
#                   :ssl_cert - the public cert file (mandatory)
# @return JSON object with pxp-agent config
# @raise ArgumentError if one of the mandatory config keys is not passed into the method
def pxp_config_json(broker, agent, ssl_config = {})
  mandatory_config_keys = [:ssl_key, :ssl_ca_cert, :ssl_cert]
  missing_config = mandatory_config_keys - ssl_config.keys
  if (missing_config != [])
    raise ArgumentError.new("Mandatory SSL config values are missing from ssl_config passsed into method: #{missing_config.to_s}")
  end
  if not ssl_config[:broker_ws_uri]
    ssl_config[:broker_ws_uri] = broker_ws_uri(broker)
  end
  { "broker-ws-uri" => ssl_config[:broker_ws_uri],
    "ssl-key" => ssl_config[:ssl_key],
    "ssl-ca-cert" => ssl_config[:ssl_ca_cert],
    "ssl-cert" => ssl_config[:ssl_cert]
  }.to_json
end

def pxp_config_json_using_puppet_certs(broker, agent)
  pxp_config_hash_using_puppet_certs(broker, agent).to_json
end

def pxp_config_hash_using_puppet_certs(broker, agent)
  on(agent, puppet('config print ssldir')) do |result|
    puppet_ssldir = result.stdout.chomp
    return { "broker-ws-uri" => "#{broker_ws_uri(broker)}",
      "ssl-key" => "#{puppet_ssldir}/private_keys/#{agent}.pem",
      "ssl-ca-cert" => "#{puppet_ssldir}/certs/ca.pem",
      "ssl-cert" => "#{puppet_ssldir}/certs/#{agent}.pem"
    }
  end
end

# @param broker_host the host name or beaker host object for the pcp-broker host
# @return the broker-ws-uri config string
def broker_ws_uri(broker_host)
  "wss://#{broker_host}:#{PCP_BROKER_PORT}/pcp/"
end

# @param host the beaker host (to determine the correct path for the OS)
# @return path to the pxp-agent.conf file for that host (a cygpath in the case of Windows)
def pxp_agent_config_file(host)
  windows?(host)?
    "#{PXP_CONFIG_DIR_CYGPATH}pxp-agent.conf" :
    "#{PXP_CONFIG_DIR_POSIX}pxp-agent.conf"
end
