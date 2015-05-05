require 'pry'

require 'dynflow'

require 'smart_proxy_ssh/version'
require 'smart_proxy_ssh/dynflow'
require 'smart_proxy_ssh/plugin'
require 'smart_proxy_ssh/api'

module Proxy::Ssh

  def self.dynflow
    @dynflow ||= Proxy::Ssh::Dynflow.new
  end
end
