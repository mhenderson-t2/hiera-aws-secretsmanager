require 'puppet'
require 'puppet/functions'

Puppet::Functions.create_function(:hiera_aws_secretsmanager) do
  # An implementation of a lookup_key Puppet Function for Hiera.
  # Looks up keys in AWS Secrets Manager.
  #
  # @param base Hiera key, e.g. `mydb::myuser::mypassword`
  #
  # @option options 'uri' contains an interpolated value from the uris
  # list in hiera.yaml. Puppet handles iterating over all possible
  # interpolations for us, yay!
  #
  # @param A Puppet::LookupContext passed from Puppet
  #
  # (The type of :context SHOULD be Puppet::LookupContext, but it is
  # ridiculously hard to instantiate or mock a Puppet::LookupContext
  # from RSpec, so this is a stupid workaround. I ... hope(?)  this
  # bug will contain the fix that allows creating a real
  # Puppet::LookupContext.)
  dispatch :lookup_key do
    param 'String', :key
    param 'Hash', :options
    param 'Any', :context
  end

  begin
    require 'aws-sdk-secretsmanager'
  rescue LoadError
    raise Puppet::DataBinding::LookupError, 'hiera_aws_secretsmanager requires the aws-sdk-secretsmanager gem installed'
  end

  # Lame explicit check for already defined constants courtesy of
  # Puppet feeling the need to reload this file over and over.
  unless defined? LIST_SECRETS_MAX
    LIST_SECRETS_MAX = 100
    SECRETS_LIST_KEY = '_hiera_aws_seretsmanager_key_list_'.freeze
    SMCLIENT_KEY = '_hiera_aws_secretsmanager_smclient_'.freeze
  end

  def lookup_key(key, options, context)
    @context = context
    unless options.include? 'uri'
      raise ArgumentError, "either 'uri' or 'uris' must be set in hiera.yaml"
    end

    secret_name = "#{options['uri']}/#{key}"
    if secret_exists? secret_name then
      return cached_secret(secret_name)
    else
      return @context.not_found
    end
  end

  private

  def smclient
    unless @context.cache_has_key(SMCLIENT_KEY)
      # No arguments being passed. We expect SDK configuration to
      # happen exclusively in the environment (including
      # $HOME/.aws/credentials, etc)
      @context.cache(SMCLIENT_KEY, Aws::SecretsManager::Client.new)
    end

    @context.cached_value(SMCLIENT_KEY)
  end

  def cached_secret(secret_name)
    unless @context.cache_has_key(secret_name)
      secret = smclient.get_secret_value(secret_id: secret_name)
      @context.cache(secret_name, secret.secret_string)
    end

    @context.cached_value(secret_name)
  end

  def cached_secrets_list
    unless @context.cache_has_key(SECRETS_LIST_KEY)
      batch = smclient.list_secrets(max_results: LIST_SECRETS_MAX)
      secrets_list = batch.secret_list.map(&:name)
      while batch.next_token do
        batch = smclient.list_secrets(max_results: LIST_SECRETS_MAX, next_token: batch.next_token)
        secrets_list.concat batch.secret_list.map(&:name)
      end
      @context.cache(SECRETS_LIST_KEY, secrets_list)
    end

    @context.cached_value(SECRETS_LIST_KEY)
  end

  def secret_exists?(secret_name)
    @context.cache_has_key(secret_name) or cached_secrets_list.include? secret_name
  end
end
