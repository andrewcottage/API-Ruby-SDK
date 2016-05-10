require 'rest_client'
require 'json'
require 'logger'
require 'cgi'
require 'trackvia-api-sdk/exceptions'

# == Trackvia API Ruby SDK
#
# Provides access to Trackvia's API (go.api.trackvia.com) for several capabilities, listed below.
#
# === Authentication
#
# You would authenticate as a user of your application, who has been given permission to access the
# application's table data via configured forms/roles.
#
# Typically you would only need to supply your API key when constructing a client.
#
#   @client = Trackvia::Client.new(user_key: '1234abcd')
#
# Then authenticate once before using:
#
#   @client.authorize('username', 'password')
#
# authorize() will raise a Trackvia::ApiError if the credentials are invalid.
#
# Once authenticated, the client will hold an OAuth2 access token and a refresh token, used to obtain a new
# access token when the current one expires.
#
# When your access token expires, the next client method invocation will trigger automatic token refresh.  When it
# succeeds, the call will take longer but otherwise be transparent to the caller.
#
# If token refresh fails, the client will raise a Trackvia::ApiError.
#
# === Authentication (client developers)
#
# There are more options to deal with varied environments.
#
#   @client = Trackvia::Client.new(scheme: "http", host: "localhost", port: 8080, base_path: "/", user_key: "12345")
#
# 'base_path' is normally set to "/" for use with the production Trackvia service.  For internal
# testing purposes, it can be set to a different root path to match the server's root context, the
# location of the application's resources on the web server.
#
# === Views
#
# Once authenticated, use views to read or write data.  You will need the view's identifier, which can
# be obtained either by looking it up by the view's name or by gleaning it from the Trackvia UI.
#
#   @client.getViews() or @client.getView("view name")
#
# A view identifier is required for managing records and files.
#
# === Records
#
# Records define data structure.  Access record data as you would a map:
#
#   record = { 'firstName' => 'Dave', 'lastName' => 'Albright'}
#   record["firstName"] = 'Dave'
#   record["lastName"] = 'Albright'
#
# Records are found according to the view they belong in.
#
#   view_id = 1
#   query_string = 'Dave'
#   start_index = 0
#   max_results = 50
#
#   records = @client.find_records(view_id, query_string, start_index, max_results)
#
# The results stored in the 'records' map contains two entries, a 'structure' entry and a 'data' entry.  'structure'
# provides metadata about each field found in records.  'data' is an array of record maps.
#
# For example:
#
#   {
#     "structure" => [
#       {
#         "name" => "Name",
#         "type" => "shortAnswer",
#         "required" => false,
#         "unique" => false,
#         "canRead" => true,
#         "canUpdate" => false,
#         "canCreate" => false
#       }
#     ],
#     "data" => [
#       { "name" => "Bob Dobbs" },
#       { "name" => "Lucy Skyward" }
#     ]
#   }
#
# You can get all records for small tables.
#
#   view_id = 1
#   records = @client.getRecords(view_id)
#
# You can get a single record using its identifier.
#
#   view_id = 1
#   record_id = 2
#   record = @client.get_record(view_id, record_id)
#
# Record creation requires you provide an array of records (maps), similar in structure to the example above.
#
#   view_id = 1
#   record1 = { 'name' => 'Bob Dobbs' }
#   record2 = { 'name' => 'Larry Lordly' }
#   batch_of_records = { 'data' => [ record1, record2 ] }
#   created = @client.create_records(view_id, batch_of_records)
#
# Updating and deleting records follow a similar pattern.
#
#   view_id = 1
#   record_id = 2
#   updated_record = { ... }
#
#   @client.delete_record(view_id, record_id)
#   @client.update_record(view_id, record_id, updated_record)
#
# === Files
#
# Tables can have "file" fields, allowing file content to be uploaded/downloaded.
#
#   view_id = 1
#   record_id = 2
#   filename = 'contractDoc'
#   local_file_path = '/path/to/my/contract/doc'
#
#   @client.add_file(view_id, record_id, filename, local_file_path)
#   @client.get_file(view_id, record_id, filename, local_file_path)
#   @client.delete_file(view_id, record_id, filename)
#
# === Apps
#
# Gets all available applications.
#
#   apps = @client.get_apps()
#
# === Users
#
# You can administratively lookup and create users.
#
#   start_index = 0
#   max_results = 25
#   users = @client.get_users(start_index, max_results)
#   user = @client.create_user("me@example.com", "Richard", "Moby", "America/Denver")
#
module Trackvia
  $LOG = Logger.new('trackvia_client.log', 7)

  class Client
    DEFAULT_BASE_PATH = "/"
    DEFAULT_SCHEME = "https"
    DEFAULT_HOST = "go.trackvia.com"
    DEFAULT_PORT = 443 
    OAUTH_CLIENT_ID = "xvia-webapp"

    def initialize(scheme: DEFAULT_SCHEME, host: DEFAULT_HOST, port: DEFAULT_PORT, base_path: DEFAULT_BASE_PATH, user_key: '')
      @scheme = scheme
      @host = host
      @port = port
      @base_path = base_path
      @user_key = user_key
    end

    def maybe_raise_trackvia_error(e)
      if e.response.nil? || e.response == ''
        raise
      else
        t = JSON.parse(e.response)
        raise Trackvia::ApiError.new(e, t["errors"], t["message"], t["name"], t["code"], t["stackTrace"], t["error"], t["description"])
      end
    end

    # Attempts to refresh a bad auth token and allow the library to retry a remote API call.  Only try this
    # when the API returns an invalid_grant or invalid_token error.
    #
    # Either return true if the caller should retry or raise an exception if the refresh fails.
    #
    def maybe_retry_when_bad_auth_token(e)
      if e.response.nil? || e.response == ''
        $LOG.debug("No Trackvia exception information in the response; re-raising given exception")
        raise
      else
        t = JSON.parse(e.response)

        ex_name = (t["name"].nil?) ? (t["error"]) : (t["name"])

        case ex_name
          when "invalid_grant", "invalid_token"
            $LOG.debug("Found an #{ex_name} exception; trying refresh_token")
            refresh_token
            # refresh_token will raise an exception if it fails.
            true
          else
            raise Trackvia::ApiError.new(e, t["errors"], t["message"], ex_name, t["code"], t["stackTrace"], t["error"], t["description"])
        end
      end
    end

    def base_uri
      "#{@scheme}://#{@host}:#{@port}#{@base_path}"
    end

    def auth_params
      { 'access_token' => @access_token_value, 'user_key' => @user_key  }
    end

    def encoded_auth_url
      encoded_access_token = (@access_token_value.nil?) ? ('') : (CGI::escape(@access_token_value))

      "access_token=#{encoded_access_token}&user_key=#{CGI::escape(@user_key)}"
    end

    # Invalidates an authentication token, intended as support for testing automatic token refresh.
    #
    def invalidate_auth_token
      @access_token_value = nil
    end

    # Refresh the access token, when it becomes invalid after expiring.
    #
    def refresh_token
      raise Trackvia::InvalidRefreshToken('Try authorize() first') if (@refresh_token_value.nil?)

      begin
        url = "#{base_uri}/oauth/token"

        json = RestClient.get url, { :params => {'client_id' => OAUTH_CLIENT_ID, 'grant_type' => 'refresh_token',
          'refresh_token' => "#{@refresh_token_value}", 'redirect_uri' => ''}, :accept => :json }
        token = JSON.parse(json)

        @access_token_value = token["value"]
        @refresh_token_value = token["refreshToken"]["value"]

      rescue RestClient::Exception => e
        maybe_raise_trackvia_error(e)
      end
    end

    # Authorize an account user using password authentication, resulting in a cached access and refresh
    # token pair.  The client will use this pair for all method invocations, including automatic token
    # refresh when the primary access token becomes invalid for whatever reason.
    #
    def authorize(username, password)
      @username = username
      @password = password
      @access_token_value = nil
      @refresh_token_value = nil

      begin
        url = "#{base_uri}/oauth/token"

        json = RestClient.get url, { :params => {'username' => @username, 'password' => @password,
          'client_id' => OAUTH_CLIENT_ID, 'grant_type' => 'password'}, :accept => :json }
        token = JSON.parse(json)

        @access_token_value = token["value"]
        @refresh_token_value = token["refreshToken"]["value"]

      rescue RestClient::Exception => e
        maybe_raise_trackvia_error(e)
      end
    end

    # Gets accessible account users, limited by the given 'start' and 'max' results.
    #
    def get_users(start: 0, max: 100)
      begin
        url = "#{base_uri}/openapi/users"

        json = RestClient.get url , { :params => auth_params.merge({ 'start' => start, 'max' => max }),
                                      :accept => :json }
        users = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      users
    end

    # Creates a new account user, managed by the authenticated account user.  The new user starts
    # at the email verification state.
    #
    # The 'time_zone' parameter is a 'tz database' timezone specifier (e.g., Amercia/Denver)
    #
    # See http://en.wikipedia.org/wiki/List_of_tz_database_time_zones
    #
    def create_user(email, first_name, last_name, time_zone)
      begin
        url = "#{base_uri}/openapi/users"

        json = RestClient.post url, auth_params.merge({ 'email' => email, 'first_name' => first_name,
          'last_name' => last_name, 'time_zone' => time_zone }), { :accept => :json }
        user = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      user
    end

    # Gets all accessible apps managed by the authenticated account user.
    #
    def get_apps
      begin
        url = "#{base_uri}/openapi/apps"

        json = RestClient.get url, { :params => auth_params, :accept => :json }
        apps = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      apps
    end

    # Gets an accessible view, managed by the authenticated account user.
    #
    def get_view(view_id)
      begin
        url = "#{base_uri}/openapi/views"

        json = RestClient.get url, { :params => auth_params.merge({ 'viewId' => view_id }), :accept => :json }
        views = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      (views.nil?) ? (nil) : (views.at(0))
    end

    def get_view_structure(view_id)
      begin
        url="#{base_uri}/openapi/views/#{view_id}/view_structure"

        json = RestClient.get url,{ :params => auth_params, :accept => :json }
        structure = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      (structure.nil?) ? (nil) : (structure.at(0))
    end

    # Gets all accessible views managed by the authenticated account user.
    #
    def get_views
      begin
        url = "#{base_uri}/openapi/views"

        json = RestClient.get url, { :params => auth_params, :accept => :json }
        views = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      views
    end

    # Finds accessible records matching given search criteria in the authorized view, returning records maps.
    #
    # The 'query_string' parameter is compared to all record fields using a substring match algorithm.
    #
    def find_records(view_id, query_string, start: 0, max: 100)
      begin
        url = "#{base_uri}/openapi/views/#{view_id}/find"

        json = RestClient.get url, { :params => auth_params.merge({ 'q' => query_string, 'start' => start, 'max' => max }),
                                     :accept => :json }
        records = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      records
    end

    # Gets all accessible records accessible in the authorized view.
    #
    def get_records(view_id, start = 0, max = 1000)
      begin
        url = "#{base_uri}/openapi/views/#{view_id}"

        json = RestClient.get url, { :params => auth_params.merge({'start' => start, 'max' => max}), :accept => :json }
        records = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      records
    end

    # Gets an accessible record in the authorized view for a specific record identifier.
    #
    def get_record(view_id, record_id)
      begin
        url = "#{base_uri}/openapi/views/#{view_id}/records/#{record_id}"

        json = RestClient.get url, { :params => auth_params, :accept => :json }
        record = JSON.parse(json)

      rescue RestClient::ResourceNotFound
        # nothing to do other than return nil
        record = nil

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      record
    end

    # Creates one or more new records in the authorized view.  The new records will be found in
    # the table for which the view maps onto.
    #
    def create_records(view_id, batch)
      begin
        url = "#{base_uri}/openapi/views/#{view_id}/records?#{encoded_auth_url}"
        new_records = { "data" => batch }

        json = RestClient.post url, new_records.to_json, { :accept => :json, :content_type => :json }
        records = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      records
    end

    # Updates an accessible record in the authorized view.  The authenticated user must have form-level
    # write access to the fields in the given 'record' parameter.
    #
    def update_record(view_id, record_id, record)
      # FIXME: Excluding these 2 fields, provided in record retrievals by the service, should happen in the service.
      copy = record.clone
      copy.delete("id")
      copy.delete("Record ID")
      batch = { "data" => [ copy ] }

      begin
        url = "#{base_uri}/openapi/views/#{view_id}/records/#{record_id}?#{encoded_auth_url}"

        json = RestClient.put url, batch.to_json, { :accept => :json, :content_type => :json }
        record = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      record
    end

    # Deletes an accessible record in the authorized view.  The authenticated user must have form-level
    # write permission to delete the record identified by the 'record_id' parameter.
    #
    def delete_record(view_id, record_id)
      begin
        url = "#{base_uri}/openapi/views/#{view_id}/records/#{record_id}"

        RestClient.delete url, { :params => auth_params, :accept => :json }

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end
    end

    # Adds a file to an accessible record in the authorized view.
    #
    # The 'file_path' parameter is an regular file-system path, according to your operating system.
    #
    def add_file(view_id, record_id, record_filename, file_path)
      begin
        url = "#{base_uri}/openapi/views/#{view_id}/records/#{record_id}/files/#{record_filename}?#{encoded_auth_url}"

        request = RestClient::Request.new(
            :method => :post,
            :url => url,
            :payload => {
                :multipart => true,
                :file => File.new(file_path, 'rb')
            },
            :headers => { :accept => :json }
        )
        json = request.execute
        record = JSON.parse(json)

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end

      record
    end

    # Deletes a file accessible in the authorized view.  The 'record_filename' parameter corresponds to a
    # column name on the table for which the view maps onto.
    #
    def delete_file(view_id, record_id, record_filename)
      begin
        url = "#{base_uri}/openapi/views/#{view_id}/records/#{record_id}/files/#{record_filename}"

        RestClient.delete url, { :params => auth_params, :accept => :json }

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end
    end

    # Get a file accessible in the authorized view.
    def get_file(view_id, record_id, record_filename, file_path)
      begin
        url = "#{base_uri}/openapi/views/#{view_id}/records/#{record_id}/files/#{record_filename}"

        response = RestClient.get url, { :params => auth_params, :accept => :json }

        File.open(file_path, 'wb') do |file|
          begin
            file << response.body
          ensure
            file.close unless file.nil?
          end
        end

      rescue RestClient::Exception => e
        retry if maybe_retry_when_bad_auth_token(e)
      end
    end

    private :maybe_raise_trackvia_error, :maybe_retry_when_bad_auth_token, :base_uri, :auth_params, :encoded_auth_url
  end
end
